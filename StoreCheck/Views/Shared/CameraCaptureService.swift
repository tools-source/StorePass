import AVFoundation
import UIKit
import SwiftUI

final class CameraCaptureService: ObservableObject {

    // MARK: - Public
    let session = AVCaptureSession()

    @Published var lastErrorMessage: String?

    // MARK: - Private
    private let sessionQueue = DispatchQueue(label: "com.storecheck.camera.sessionQueue")
    private var isConfigured = false
    private var isConfiguring = false
    private var isStarting = false
    private var isAuthorizedForCamera = false

    private let photoOutput = AVCapturePhotoOutput()
    private var activeVideoConnection: AVCaptureConnection?

    private var currentPosition: AVCaptureDevice.Position = .front

    // Keep strong ref while capture is in-flight
    private var inFlightPhotoDelegate: PhotoCaptureDelegate?

    // MARK: - Init
    init() {}

    // MARK: - Permissions
    func requestCameraPermissionIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        PhotoVerifyLogger.log("[Camera] permission status=\(status.rawValue)")

        switch status {
        case .authorized:
            isAuthorizedForCamera = true
            DispatchQueue.main.async {
                self.lastErrorMessage = nil
            }
            PhotoVerifyLogger.log("[Camera] permission already authorized")
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorizedForCamera = granted
            PhotoVerifyLogger.log("[Camera] permission request result granted=\(granted)")
            if !granted {
                postError("Camera access is denied. Enable camera permission in Settings.")
            } else {
                DispatchQueue.main.async {
                    self.lastErrorMessage = nil
                }
            }
            return granted
        case .denied, .restricted:
            isAuthorizedForCamera = false
            PhotoVerifyLogger.log("[Camera] permission denied_or_restricted")
            postError("Camera access is denied or restricted. Enable camera permission in Settings.")
            return false
        @unknown default:
            isAuthorizedForCamera = false
            PhotoVerifyLogger.log("[Camera] permission unknown status")
            postError("Unable to determine camera permission status.")
            return false
        }
    }

    // MARK: - Session lifecycle
    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.isConfigured {
                PhotoVerifyLogger.log("[Camera] configure skipped: already configured")
                return
            }

            if self.isConfiguring {
                PhotoVerifyLogger.log("[Camera] configure skipped: configuration already in progress")
                return
            }

            guard self.isAuthorizedForCamera else {
                PhotoVerifyLogger.log("[Camera] configure blocked: camera permission not granted")
                self.postError("Camera permission is required before starting capture.")
                return
            }

            self.isConfiguring = true

            DispatchQueue.main.async {
                self.lastErrorMessage = nil
            }

            PhotoVerifyLogger.log("[Camera] configure begin")
            self.session.beginConfiguration()
            defer {
                self.session.commitConfiguration()
                self.isConfiguring = false
                PhotoVerifyLogger.log("[Camera] configure end")
            }

            // Pick a preset that works broadly
            if self.session.canSetSessionPreset(.photo) {
                self.session.sessionPreset = .photo
            } else if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }

            // Clean inputs/outputs (safe reconfigure)
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            // 1) Choose device (front preferred)
            let chosen = self.selectDevice(position: self.currentPosition) ?? self.selectDevice(position: .back)
            guard let device = chosen else {
                self.fail("No camera device available.")
                return
            }

            // 2) Input
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.fail("Unable to add camera input.")
                    return
                }
                self.session.addInput(input)
            } catch {
                self.fail("Camera input error: \(error.localizedDescription)")
                return
            }

            // 3) Output
            guard self.session.canAddOutput(self.photoOutput) else {
                self.fail("Unable to add photo output.")
                return
            }
            self.session.addOutput(self.photoOutput)

            // Cache the video connection (rotation)
            self.activeVideoConnection = self.photoOutput.connection(with: .video)
            if self.activeVideoConnection == nil {
                PhotoVerifyLogger.log("[Camera] warning: no active video connection after configure")
            }

            self.isConfigured = true
            PhotoVerifyLogger.log("[Camera] configured ok position=\(device.position.rawValue) preset=\(self.session.sessionPreset.rawValue)")
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                PhotoVerifyLogger.log("[Camera] start skipped: not configured")
                return
            }

            if self.session.isRunning {
                PhotoVerifyLogger.log("[Camera] start skipped: already running")
                return
            }

            if self.isStarting {
                PhotoVerifyLogger.log("[Camera] start skipped: start already in progress")
                return
            }

            self.isStarting = true
            PhotoVerifyLogger.log("[Camera] session start requested")
            self.session.startRunning()
            self.isStarting = false
            PhotoVerifyLogger.log("[Camera] session started running=\(self.session.isRunning)")
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                PhotoVerifyLogger.log("[Camera] stop skipped: already stopped")
                return
            }

            PhotoVerifyLogger.log("[Camera] session stop requested")
            self.session.stopRunning()
            PhotoVerifyLogger.log("[Camera] session stopped running=\(self.session.isRunning)")
        }
    }

    // MARK: - Rotation (iOS 17+ safe)
    func updateRotationForCurrentDevice() {
        let orientation = UIDevice.current.orientation
        let angle = Self.rotationAngle(for: orientation)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else {
                PhotoVerifyLogger.log("[Camera] rotation skipped: session not configured orientation=\(orientation.rawValue)")
                return
            }

            guard let connection = self.activeVideoConnection else {
                self.activeVideoConnection = self.photoOutput.connection(with: .video)
                guard let refreshedConnection = self.activeVideoConnection else {
                    PhotoVerifyLogger.log("[Camera] rotation skipped: no video connection orientation=\(orientation.rawValue)")
                    return
                }

                self.applyRotationAngle(angle, to: refreshedConnection)
                return
            }

            self.applyRotationAngle(angle, to: connection)
        }
    }

    private func applyRotationAngle(_ angle: Double, to connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
            PhotoVerifyLogger.log("[Camera] rotation applied angle=\(angle)")
        } else {
            PhotoVerifyLogger.log("[Camera] rotation not supported angle=\(angle)")
        }
    }

    func updateVideoRotationAngle(_ angle: Double) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.activeVideoConnection else { return }

            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                PhotoVerifyLogger.log("[Camera] set videoRotationAngle=\(angle)")
            } else {
                PhotoVerifyLogger.log("[Camera] rotationAngle not supported: \(angle)")
            }
        }
    }

    // MARK: - Capture
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            PhotoVerifyLogger.log("[Camera] capture requested")

            guard self.isConfigured else {
                self.postError("Camera not ready yet. Try again.")
                PhotoVerifyLogger.log("[Camera] capture blocked: not configured")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if !self.session.isRunning {
                PhotoVerifyLogger.log("[Camera] capture blocked: session not running")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let connection = self.photoOutput.connection(with: .video) else {
                PhotoVerifyLogger.log("[Camera] capture blocked: no photo output video connection")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if connection.isVideoRotationAngleSupported(connection.videoRotationAngle) {
                self.activeVideoConnection = connection
            }

            // Build settings
            let settings = AVCapturePhotoSettings()

            // ✅ Prevent crash: settings.photoQualityPrioritization must NOT exceed output.max
            let maxQ = self.photoOutput.maxPhotoQualityPrioritization
            let desired: AVCapturePhotoOutput.QualityPrioritization = .quality
            let finalQ: AVCapturePhotoOutput.QualityPrioritization =
                (desired.rawValue <= maxQ.rawValue) ? desired : maxQ
            settings.photoQualityPrioritization = finalQ

            // Flash off by default
            if self.photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }

            PhotoVerifyLogger.log(
                "[Camera] capturePhoto maxQ=\(maxQ.rawValue) desired=\(desired.rawValue) final=\(finalQ.rawValue) running=\(self.session.isRunning)"
            )

            let delegate = PhotoCaptureDelegate { [weak self] image in
                guard let self else { return }
                self.inFlightPhotoDelegate = nil
                PhotoVerifyLogger.log("[Camera] capture completed success=\(image != nil)")
                DispatchQueue.main.async {
                    completion(image)
                }
            }

            self.inFlightPhotoDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Private helpers

    private func selectDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera
        ]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        )

        if let first = discovery.devices.first {
            PhotoVerifyLogger.log("[Camera] selected device position=\(position.rawValue) name=\(first.localizedName)")
            return first
        }

        PhotoVerifyLogger.log("[Camera] no device for position=\(position.rawValue)")
        return nil
    }

    private static func rotationAngle(for orientation: UIDeviceOrientation) -> Double {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .faceUp, .faceDown, .unknown: return 90
        @unknown default: return 90
        }
    }

    private func fail(_ message: String) {
        PhotoVerifyLogger.log("[Camera] FAIL: \(message)")
        postError(message)
    }

    private func postError(_ message: String) {
        DispatchQueue.main.async {
            self.lastErrorMessage = message
        }
    }
}

// MARK: - Delegate
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onImage: (UIImage?) -> Void

    init(onImage: @escaping (UIImage?) -> Void) {
        self.onImage = onImage
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            PhotoVerifyLogger.log("[Camera] didFinishProcessingPhoto error=\(error.localizedDescription)")
            onImage(nil)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            PhotoVerifyLogger.log("[Camera] fileDataRepresentation nil")
            onImage(nil)
            return
        }

        let image = UIImage(data: data)
        if let image {
            PhotoVerifyLogger.log("[Camera] image ok size=\(Int(image.size.width))x\(Int(image.size.height))")
        } else {
            PhotoVerifyLogger.log("[Camera] UIImage(data:) failed")
        }
        onImage(image)
    }
}
