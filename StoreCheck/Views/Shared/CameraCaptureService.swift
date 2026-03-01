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
    @MainActor
    func requestCameraPermissionIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        CameraLog.log("[Camera] permission status=\(status.rawValue)")

        switch status {
        case .authorized:
            isAuthorizedForCamera = true
            lastErrorMessage = nil
            return true

        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorizedForCamera = granted
            CameraLog.log("[Camera] permission request granted=\(granted)")
            if granted {
                lastErrorMessage = nil
            } else {
                lastErrorMessage = "Camera access is denied. Enable camera permission in Settings."
            }
            return granted

        case .denied, .restricted:
            isAuthorizedForCamera = false
            lastErrorMessage = "Camera access is denied or restricted. Enable camera permission in Settings."
            return false

        @unknown default:
            isAuthorizedForCamera = false
            lastErrorMessage = "Unable to determine camera permission status."
            return false
        }
    }

    // MARK: - Session lifecycle
    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.isConfigured {
                CameraLog.log("[Camera] configure skipped: already configured")
                return
            }
            if self.isConfiguring {
                CameraLog.log("[Camera] configure skipped: already configuring")
                return
            }
            guard self.isAuthorizedForCamera else {
                CameraLog.log("[Camera] configure blocked: permission not granted")
                self.postError("Camera permission is required before starting capture.")
                return
            }

            self.isConfiguring = true
            CameraLog.log("[Camera] configure begin")

            // IMPORTANT: don’t configure while running
            if self.session.isRunning {
                CameraLog.log("[Camera] configure: session is running → stopping first")
                self.session.stopRunning()
            }

            self.session.beginConfiguration()
            defer {
                self.session.commitConfiguration()
                self.isConfiguring = false
                self.isConfigured = true
                CameraLog.log("[Camera] configure end (configured=\(self.isConfigured))")
            }

            // Preset
            if self.session.canSetSessionPreset(.photo) {
                self.session.sessionPreset = .photo
            } else if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }

            // Remove old inputs/outputs
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }

            // Device: wide angle only (avoids BackTriple / BackAuto issues)
            let device =
                self.selectDevice(position: .front) ??
                self.selectDevice(position: .back)

            guard let selectedDevice = device else {
                self.fail("No camera device available.")
                return
            }

            // Input
            do {
                let input = try AVCaptureDeviceInput(device: selectedDevice)
                guard self.session.canAddInput(input) else {
                    self.fail("Unable to add camera input.")
                    return
                }
                self.session.addInput(input)
            } catch {
                self.fail("Camera input error: \(error.localizedDescription)")
                return
            }

            // Output
            guard self.session.canAddOutput(self.photoOutput) else {
                self.fail("Unable to add photo output.")
                return
            }
            self.session.addOutput(self.photoOutput)

            // Cache connection
            self.activeVideoConnection = self.photoOutput.connection(with: .video)

            CameraLog.log("[Camera] configured ok device=\(selectedDevice.position.rawValue) preset=\(self.session.sessionPreset.rawValue)")
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                CameraLog.log("[Camera] start skipped: not configured")
                return
            }
            if self.isConfiguring {
                CameraLog.log("[Camera] start skipped: configuring in progress")
                return
            }
            if self.session.isRunning {
                CameraLog.log("[Camera] start skipped: already running")
                return
            }
            if self.isStarting {
                CameraLog.log("[Camera] start skipped: start in progress")
                return
            }

            self.isStarting = true
            CameraLog.log("[Camera] startRunning…")
            self.session.startRunning()
            self.isStarting = false
            CameraLog.log("[Camera] started running=\(self.session.isRunning)")
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                CameraLog.log("[Camera] stop skipped: already stopped")
                return
            }
            CameraLog.log("[Camera] stopRunning…")
            self.session.stopRunning()
        }
    }

    // MARK: - Rotation (iOS 17+ safe, angle only)
    /// Call this after `startSession()` (or on orientation changes if you want).
    func updateRotationForCurrentDevice() {
        let angle = Self.rotationAngle(for: UIDevice.current.orientation)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.activeVideoConnection ?? self.photoOutput.connection(with: .video) else {
                CameraLog.log("[Camera] rotation skipped: no connection")
                return
            }
            self.activeVideoConnection = connection

            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                CameraLog.log("[Camera] rotation applied angle=\(angle)")
            } else {
                CameraLog.log("[Camera] rotation not supported angle=\(angle)")
            }
        }
    }

    // MARK: - Capture
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            CameraLog.log("[Camera] capture requested")

            guard self.isConfigured else {
                self.postError("Camera not ready yet. Try again.")
                CameraLog.log("[Camera] capture blocked: not configured")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard self.session.isRunning else {
                self.postError("Camera is starting… please try again.")
                CameraLog.log("[Camera] capture blocked: session not running")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Settings
            let settings = AVCapturePhotoSettings()

            // Prevent crash: prioritization must not exceed max
            let maxQ = self.photoOutput.maxPhotoQualityPrioritization
            let desired: AVCapturePhotoOutput.QualityPrioritization = .quality
            let finalQ: AVCapturePhotoOutput.QualityPrioritization =
                (desired.rawValue <= maxQ.rawValue) ? desired : maxQ
            settings.photoQualityPrioritization = finalQ

            // Flash off
            if self.photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }

            CameraLog.log("[Camera] capture settings maxQ=\(maxQ.rawValue) desired=\(desired.rawValue) final=\(finalQ.rawValue)")

            let delegate = PhotoCaptureDelegate { [weak self] image in
                guard let self else { return }
                self.inFlightPhotoDelegate = nil
                CameraLog.log("[Camera] capture completed success=\(image != nil)")
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
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        if let device = discovery.devices.first {
            CameraLog.log("[Camera] selected device position=\(position.rawValue) name=\(device.localizedName)")
            return device
        }
        CameraLog.log("[Camera] no device for position=\(position.rawValue)")
        return nil
    }

    private static func rotationAngle(for orientation: UIDeviceOrientation) -> Double {
        // Portrait UI default
        switch orientation {
        case .portrait: return 0
        case .portraitUpsideDown: return 180
        case .landscapeLeft: return 90
        case .landscapeRight: return 270
        case .faceUp, .faceDown, .unknown: return 0
        @unknown default: return 0
        }
    }

    private func fail(_ message: String) {
        CameraLog.log("[Camera] FAIL: \(message)")
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
            CameraLog.log("[Camera] didFinishProcessingPhoto error=\(error.localizedDescription)")
            onImage(nil)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            CameraLog.log("[Camera] fileDataRepresentation nil")
            onImage(nil)
            return
        }

        let image = UIImage(data: data)
        if let image {
            CameraLog.log("[Camera] image ok size=\(Int(image.size.width))x\(Int(image.size.height))")
        } else {
            CameraLog.log("[Camera] UIImage(data:) failed")
        }
        onImage(image)
    }
}

// MARK: - Local logger (prevents PhotoVerifyLogger redeclare conflicts)
private enum CameraLog {
    static func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}
