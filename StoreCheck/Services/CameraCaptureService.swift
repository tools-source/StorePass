import AVFoundation
import SwiftUI

@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published private(set) var isSessionRunning = false
    @Published private(set) var lastErrorMessage: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.storecheck.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false

    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isConfigured else {
                self.log("configureSessionIfNeeded skipped; already configured")
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            do {
                let device = try self.chooseCaptureDevice()
                let input = try AVCaptureDeviceInput(device: device)

                guard self.session.canAddInput(input) else {
                    throw CameraError.unableToAddInput
                }
                self.session.addInput(input)
                self.videoDeviceInput = input
                self.log("chosen device type=\(device.deviceType.rawValue) position=\(self.string(for: device.position))")

                guard self.session.canAddOutput(self.photoOutput) else {
                    throw CameraError.unableToAddOutput
                }
                self.session.addOutput(self.photoOutput)

                if self.photoOutput.isHighResolutionCaptureEnabled {
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }

                self.isConfigured = true
                self.log("photoOutput.maxPhotoQualityPrioritization=\(self.photoOutput.maxPhotoQualityPrioritization.rawValue)")
                self.applyOrientationToConnections(.portrait)
                self.session.commitConfiguration()
            } catch {
                self.session.commitConfiguration()
                self.log("configuration failure error=\(error.localizedDescription)")
                Task { @MainActor in
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else {
                self.log("startSession requested before configuration")
                return
            }

            self.log("session start requested; session.isRunning=\(self.session.isRunning)")
            if !self.session.isRunning {
                self.session.startRunning()
                self.log("session started; session.isRunning=\(self.session.isRunning)")
            }

            Task { @MainActor in
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.log("session stop requested; session.isRunning=\(self.session.isRunning)")
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.log("session stopped; session.isRunning=\(self.session.isRunning)")
            Task { @MainActor in
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyOrientationToConnections(orientation)
        }
    }

    func capturePhoto(onCapture: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.log("capture requested; session.isRunning=\(self.session.isRunning)")
            guard self.isConfigured else {
                self.log("capture blocked: session is not configured")
                Task { @MainActor in
                    self.lastErrorMessage = CameraError.notConfigured.localizedDescription
                    onCapture(nil)
                }
                return
            }

            if !self.session.isRunning {
                self.log("capture requested while session stopped; starting session first")
                self.session.startRunning()
                self.log("session start from capture; session.isRunning=\(self.session.isRunning)")
                Task { @MainActor in
                    self.isSessionRunning = self.session.isRunning
                }
            }

            guard self.session.isRunning else {
                self.log("capture aborted because session is still not running")
                Task { @MainActor in
                    onCapture(nil)
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off

            let desired: AVCapturePhotoOutput.QualityPrioritization = .quality
            let maxQuality = self.photoOutput.maxPhotoQualityPrioritization
            let chosen = self.clampedPrioritization(desired: desired, max: maxQuality)
            settings.photoQualityPrioritization = chosen

            self.log("photoOutput.maxPhotoQualityPrioritization=\(maxQuality.rawValue)")
            self.log("chosen photoQualityPrioritization=\(chosen.rawValue)")
            self.log("capture start")

            let delegate = PhotoCaptureDelegate { image, error in
                if let error {
                    self.log("didFinishProcessingPhoto error=\(error.localizedDescription)")
                } else {
                    self.log("didFinishProcessingPhoto success=\(image != nil)")
                }

                Task { @MainActor in
                    if let error {
                        self.lastErrorMessage = error.localizedDescription
                    }
                    onCapture(image)
                }
            }

            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            self.captureDelegates[delegate.id] = delegate
            delegate.onComplete = { [weak self] in
                guard let self else { return }
                self.sessionQueue.async {
                    self.captureDelegates.removeValue(forKey: delegate.id)
                }
            }
        }
    }

    private var captureDelegates: [UUID: PhotoCaptureDelegate] = [:]

    private func chooseCaptureDevice() throws -> AVCaptureDevice {
        if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return front
        }

        if let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            return back
        }

        throw CameraError.noSupportedDevice
    }

    private func applyOrientationToConnections(_ orientation: AVCaptureVideoOrientation) {
        if let previewConnection = session.connections.first(where: { $0.inputPorts.contains(where: { $0.mediaType == .video }) }) {
            if previewConnection.isVideoOrientationSupported {
                previewConnection.videoOrientation = orientation
                log("updated preview connection orientation=\(orientation.rawValue)")
            }
        }

        if let photoConnection = photoOutput.connection(with: .video), photoConnection.isVideoOrientationSupported {
            photoConnection.videoOrientation = orientation
            log("updated photo connection orientation=\(orientation.rawValue)")
        }
    }

    private func clampedPrioritization(
        desired: AVCapturePhotoOutput.QualityPrioritization,
        max: AVCapturePhotoOutput.QualityPrioritization
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        if desired.rawValue <= max.rawValue {
            return desired
        }
        return max
    }

    private func string(for position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[Camera] \(message)")
        #endif
    }
}

private enum CameraError: LocalizedError {
    case noSupportedDevice
    case unableToAddInput
    case unableToAddOutput
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .noSupportedDevice:
            return "No supported camera device is available."
        case .unableToAddInput:
            return "Unable to add camera input to session."
        case .unableToAddOutput:
            return "Unable to add photo output to session."
        case .notConfigured:
            return "Camera is not configured yet."
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let id = UUID()
    var onComplete: (() -> Void)?

    private let completion: (UIImage?, Error?) -> Void

    init(completion: @escaping (UIImage?, Error?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(nil, error)
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            completion(nil, CameraCaptureProcessingError.invalidPhotoData)
            return
        }

        completion(image, nil)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            completion(nil, error)
        }
        onComplete?()
    }
}

private enum CameraCaptureProcessingError: LocalizedError {
    case invalidPhotoData

    var errorDescription: String? {
        switch self {
        case .invalidPhotoData:
            return "Failed to process captured photo data."
        }
    }
}
