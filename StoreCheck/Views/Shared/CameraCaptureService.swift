import AVFoundation
import SwiftUI
import UIKit

final class CameraCaptureService: ObservableObject {
    // MARK: - Public
    let session = AVCaptureSession()

    @Published private(set) var isReadyToCapture = false
    @Published var lastErrorMessage: String?

    // MARK: - Private
    private let sessionQueue = DispatchQueue(label: "com.storecheck.camera.sessionQueue")
    private let photoOutput = AVCapturePhotoOutput()

    private var isConfigured = false
    private var isConfiguring = false
    private var isStartingOrStopping = false
    private var pendingStartAfterConfiguration = false

    private var activeVideoConnection: AVCaptureConnection?
    private var currentDevicePosition: AVCaptureDevice.Position = .front

    private var notificationObservers: [NSObjectProtocol] = []

    // Keep delegate strongly referenced for capture lifecycle.
    private var inFlightPhotoDelegate: PhotoCaptureDelegate?

    // MARK: - Init
    init() {
        observeSessionNotifications()
    }

    deinit {
        removeSessionObservers()
    }

    // MARK: - Permission
    @MainActor
    func requestCameraPermissionIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        PhotoVerifyLogger.log("[Camera] permission status=\(status.rawValue)")

        switch status {
        case .authorized:
            lastErrorMessage = nil
            return true

        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            PhotoVerifyLogger.log("[Camera] permission request result granted=\(granted)")
            lastErrorMessage = granted ? nil : "Camera access is denied. Enable access in Settings."
            return granted

        case .denied, .restricted:
            lastErrorMessage = "Camera access is denied or restricted. Enable access in Settings."
            return false

        @unknown default:
            lastErrorMessage = "Unable to determine camera permission state."
            return false
        }
    }

    // MARK: - Session Lifecycle
    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.postError("Camera permission is required before starting capture.")
                self.updateReadiness(reason: "configureNoPermission")
                return
            }

            guard !self.isConfigured else {
                PhotoVerifyLogger.log("[Camera] configure skipped (already configured)")
                self.updateReadiness(reason: "configureAlreadyConfigured")
                if self.pendingStartAfterConfiguration {
                    self.pendingStartAfterConfiguration = false
                    self.startSessionOnQueue(reason: "pendingStartAlreadyConfigured")
                }
                return
            }

            guard !self.isConfiguring else {
                PhotoVerifyLogger.log("[Camera] configure skipped (already configuring)")
                return
            }

            self.isConfiguring = true
            PhotoVerifyLogger.log("[Camera] configure begin")

            self.session.beginConfiguration()
            defer {
                self.session.commitConfiguration()
                self.isConfiguring = false
                self.isConfigured = true
                self.activeVideoConnection = self.photoOutput.connection(with: .video)
                self.updateReadiness(reason: "configureFinished")
                PhotoVerifyLogger.log("[Camera] configure end configured=\(self.isConfigured)")

                if self.pendingStartAfterConfiguration {
                    self.pendingStartAfterConfiguration = false
                    self.startSessionOnQueue(reason: "pendingStartAfterConfigure")
                }
            }

            if self.session.canSetSessionPreset(.photo) {
                self.session.sessionPreset = .photo
            }

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard let camera = self.selectCameraDevice() else {
                self.fail("No supported camera device is available.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                guard self.session.canAddInput(input) else {
                    self.fail("Unable to add camera input.")
                    return
                }
                self.session.addInput(input)
                self.currentDevicePosition = camera.position
            } catch {
                self.fail("Camera input error: \(error.localizedDescription)")
                return
            }

            guard self.session.canAddOutput(self.photoOutput) else {
                self.fail("Unable to add photo output.")
                return
            }
            self.session.addOutput(self.photoOutput)

            self.activeVideoConnection = self.photoOutput.connection(with: .video)
            PhotoVerifyLogger.log("[Camera] configured device=\(camera.localizedName) position=\(camera.position.rawValue)")
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            self?.startSessionOnQueue(reason: "startSession")
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.stopSessionOnQueue(reason: "stopSession")
        }
    }

    // MARK: - Rotation
    func updateRotationForCurrentDevice() {
        let angle = Self.rotationAngleForCurrentDeviceOrientation()
        setRotationAngle(angle)
    }

    func setRotationAngle(_ angle: Double) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.photoOutput.connection(with: .video) ?? self.activeVideoConnection else {
                PhotoVerifyLogger.log("[Camera] setRotationAngle skipped (no video connection)")
                return
            }

            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                self.activeVideoConnection = connection
                PhotoVerifyLogger.log("[Camera] rotation angle applied=\(angle)")
            } else {
                PhotoVerifyLogger.log("[Camera] rotation angle unsupported=\(angle)")
            }
        }
    }

    // MARK: - Capture
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard self.isConfigured else {
                self.postError("Camera is not configured yet.")
                self.updateReadiness(reason: "captureNotConfigured")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard self.session.isRunning else {
                self.postError("Camera is not running. Please try again.")
                self.updateReadiness(reason: "captureNotRunning")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let connection = self.photoOutput.connection(with: .video) else {
                self.postError("Camera connection is unavailable.")
                self.updateReadiness(reason: "captureNoConnection")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.activeVideoConnection = connection

            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }

            let desired: AVCapturePhotoOutput.QualityPrioritization = .quality
            let maxAllowed = self.photoOutput.maxPhotoQualityPrioritization
            settings.photoQualityPrioritization = desired.rawValue <= maxAllowed.rawValue ? desired : maxAllowed

            let delegate = PhotoCaptureDelegate { [weak self] image, errorMessage in
                guard let self else { return }
                self.sessionQueue.async {
                    self.inFlightPhotoDelegate = nil
                    if let errorMessage {
                        self.postError(errorMessage)
                    }
                    DispatchQueue.main.async {
                        completion(image)
                    }
                }
            }

            self.inFlightPhotoDelegate = delegate
            PhotoVerifyLogger.log("[Camera] capture begin quality=\(settings.photoQualityPrioritization.rawValue) max=\(maxAllowed.rawValue) position=\(self.currentDevicePosition.rawValue)")
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Notifications
    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        let interrupted = center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            self.sessionQueue.async {
                let reasonNumber = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                let reasonValue = reasonNumber?.intValue ?? -1
                PhotoVerifyLogger.log("[Camera] session interrupted reason=\(reasonValue)")
                self.postError("Camera was interrupted. Please wait a moment and try again.")
                self.updateReadiness(reason: "sessionInterrupted")
            }
        }

        let interruptionEnded = center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                PhotoVerifyLogger.log("[Camera] interruption ended")
                self.clearError()
                self.startSessionOnQueue(reason: "interruptionEnded")
            }
        }

        let runtimeError = center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            self.sessionQueue.async {
                let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let code = nsError?.code ?? -1
                let domain = nsError?.domain ?? "unknown"
                PhotoVerifyLogger.log("[Camera] runtime error domain=\(domain) code=\(code)")

                if code == AVError.mediaServicesWereReset.rawValue {
                    self.startSessionOnQueue(reason: "mediaServicesWereReset")
                } else {
                    self.updateReadiness(reason: "runtimeError")
                }
            }
        }

        notificationObservers = [interrupted, interruptionEnded, runtimeError]
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach { center.removeObserver($0) }
        notificationObservers.removeAll()
    }

    // MARK: - Queue-only helpers
    private func startSessionOnQueue(reason: String) {
        guard isConfigured else {
            pendingStartAfterConfiguration = true
            PhotoVerifyLogger.log("[Camera] start deferred reason=\(reason) (not configured yet)")
            return
        }

        guard !isConfiguring else {
            pendingStartAfterConfiguration = true
            PhotoVerifyLogger.log("[Camera] start deferred reason=\(reason) (configuring in progress)")
            return
        }

        guard !session.isRunning else {
            updateReadiness(reason: "startAlreadyRunning")
            return
        }

        guard !isStartingOrStopping else {
            PhotoVerifyLogger.log("[Camera] start skipped reason=\(reason) (transition in progress)")
            return
        }

        isStartingOrStopping = true
        PhotoVerifyLogger.log("[Camera] start running reason=\(reason)")
        session.startRunning()
        isStartingOrStopping = false

        activeVideoConnection = photoOutput.connection(with: .video)
        updateReadiness(reason: "startCompleted")
    }

    private func stopSessionOnQueue(reason: String) {
        guard !isStartingOrStopping else {
            PhotoVerifyLogger.log("[Camera] stop skipped reason=\(reason) (transition in progress)")
            return
        }

        guard session.isRunning else {
            updateReadiness(reason: "stopAlreadyStopped")
            return
        }

        isStartingOrStopping = true
        PhotoVerifyLogger.log("[Camera] stop running reason=\(reason)")
        session.stopRunning()
        isStartingOrStopping = false

        updateReadiness(reason: "stopCompleted")
    }

    private func selectCameraDevice() -> AVCaptureDevice? {
        if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return front
        }

        if let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            return back
        }

        return nil
    }

    private func updateReadiness(reason: String) {
        let connection = photoOutput.connection(with: .video)
        if connection != nil {
            activeVideoConnection = connection
        }

        let ready = isConfigured && session.isRunning && (connection != nil)
        DispatchQueue.main.async {
            self.isReadyToCapture = ready
        }

        PhotoVerifyLogger.log("[Camera] readiness reason=\(reason) configured=\(isConfigured) running=\(session.isRunning) hasConnection=\(connection != nil) ready=\(ready)")
    }

    private func fail(_ message: String) {
        PhotoVerifyLogger.log("[Camera] fail: \(message)")
        postError(message)
        updateReadiness(reason: "failed")
    }

    private func postError(_ message: String) {
        DispatchQueue.main.async {
            self.lastErrorMessage = message
        }
    }

    private func clearError() {
        DispatchQueue.main.async {
            self.lastErrorMessage = nil
        }
    }

    private static func rotationAngleForCurrentDeviceOrientation() -> Double {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown:
            return 180
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return 270
        case .portrait, .faceUp, .faceDown, .unknown:
            return 0
        @unknown default:
            return 0
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?, String?) -> Void

    init(completion: @escaping (UIImage?, String?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            PhotoVerifyLogger.log("[Camera] didFinishProcessingPhoto error=\(error.localizedDescription)")
            completion(nil, "Failed to capture photo. Please try again.")
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            PhotoVerifyLogger.log("[Camera] invalid photo data")
            completion(nil, "Captured photo data was invalid.")
            return
        }

        PhotoVerifyLogger.log("[Camera] capture processed image=\(Int(image.size.width))x\(Int(image.size.height))")
        completion(image, nil)
    }
}
