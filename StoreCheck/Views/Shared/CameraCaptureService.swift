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

    private let photoOutput = AVCapturePhotoOutput()
    private var activeVideoConnection: AVCaptureConnection?

    private var currentPosition: AVCaptureDevice.Position = .front

    // Keep strong ref while capture is in-flight
    private var inFlightPhotoDelegate: PhotoCaptureDelegate?

    // MARK: - Init
    init() {}

    // MARK: - Session lifecycle
    func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        DispatchQueue.main.async {
            self.lastErrorMessage = nil
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

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

            self.isConfigured = true
            PhotoVerifyLogger.log("[Camera] configured ok position=\(device.position.rawValue) preset=\(self.session.sessionPreset.rawValue)")
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                PhotoVerifyLogger.log("[Camera] startSession called before configured; configuring now")
                self.configureSessionIfNeeded()
                return
            }

            if !self.session.isRunning {
                PhotoVerifyLogger.log("[Camera] starting session…")
                self.session.startRunning()
                PhotoVerifyLogger.log("[Camera] session running=\(self.session.isRunning)")
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                PhotoVerifyLogger.log("[Camera] stopping session…")
                self.session.stopRunning()
            }
        }
    }

    // MARK: - Rotation (iOS 17+ safe)
    /// Call this with 0/90/180/270 (or -90) depending on device orientation.
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

    /// Backward-compatible helper if your UI is still calling AVCaptureVideoOrientation.
    @available(iOS, deprecated: 17.0, message: "Use updateVideoRotationAngle(_:) instead.")
    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        updateVideoRotationAngle(Self.rotationAngle(for: orientation))
    }

    // MARK: - Capture
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard self.isConfigured else {
                self.postError("Camera not ready yet. Try again.")
                PhotoVerifyLogger.log("[Camera] capture blocked: not configured")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if !self.session.isRunning {
                PhotoVerifyLogger.log("[Camera] capture requested while session not running → starting")
                self.session.startRunning()
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

    private static func rotationAngle(for orientation: AVCaptureVideoOrientation) -> Double {
        switch orientation {
        case .portrait: return 0
        case .landscapeRight: return 90
        case .portraitUpsideDown: return 180
        case .landscapeLeft: return 270
        @unknown default: return 0
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
