import AVFoundation
import SwiftUI
import UIKit

struct CameraCaptureSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let onCaptured: (UIImage) -> Void

    @StateObject private var cameraService = CameraService()
    @State private var capturedImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.background.ignoresSafeArea()

                if let capturedImage {
                    reviewUI(image: capturedImage)
                } else if let message = cameraService.unavailableMessage {
                    unavailableUI(message: message)
                } else if cameraService.authorizationStatus == .denied || cameraService.authorizationStatus == .restricted {
                    permissionDeniedUI
                } else {
                    liveCameraUI
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .task {
            await cameraService.prepareIfNeeded()
        }
    }

    private var liveCameraUI: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(session: cameraService.session)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(DS.Spacing.l)
                .onAppear { cameraService.start() }
                .onDisappear { cameraService.stop() }

            VStack(spacing: DS.Spacing.s) {
                if let lastError = cameraService.lastError {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.l)
                }

                Button {
                    cameraService.capturePhoto { data in
                        guard let data,
                              let image = UIImage(data: data) else {
                            CameraDebugLogger.log("capture callback missing image data")
                            return
                        }
                        capturedImage = image
                    }
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 76, height: 76)
                        Circle().stroke(.black.opacity(0.8), lineWidth: 2).frame(width: 62, height: 62)
                    }
                }
                .padding(.bottom, DS.Spacing.l)
            }
        }
    }

    private var permissionDeniedUI: some View {
        VStack(spacing: DS.Spacing.s) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34))
                .foregroundStyle(DS.Colors.textSecondary)
            Text("Camera access is required to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.Colors.textPrimary)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DS.Spacing.l)
    }

    private func unavailableUI(message: String) -> some View {
        VStack(spacing: DS.Spacing.s) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(DS.Colors.textSecondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(DS.Spacing.l)
    }

    private func reviewUI(image: UIImage) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: DS.Spacing.m) {
                Button("Retake") {
                    capturedImage = nil
                    cameraService.start()
                }
                .buttonStyle(.bordered)

                Button("Use Photo") {
                    onCaptured(image)
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(DS.Spacing.l)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        if let connection = view.videoPreviewLayer.connection,
           connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}

final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let output = AVCapturePhotoOutput()

    @Published var isRunning = false
    @Published var lastError: String?
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var unavailableMessage: String?

    private var isConfigured = false
    private var pendingCaptures: [Int64: (Data?) -> Void] = [:]
    private var setupInProgress = false
    private var runtimeObserverTokens: [NSObjectProtocol] = []
    private var lastStartRequest: Date?
    private var lastStopRequest: Date?
    private var lastRecoveryAttempt: Date?

    private func publishOnMain(_ update: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            update()
        }
    }

    deinit {
        for token in runtimeObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func prepareIfNeeded() async {
        guard !setupInProgress else { return }
        setupInProgress = true

        #if targetEnvironment(simulator)
        await MainActor.run {
            self.unavailableMessage = "Camera not available on Simulator."
        }
        CameraDebugLogger.log("simulatorDetected; camera setup skipped")
        setupInProgress = false
        return
        #endif

        let initialAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        await MainActor.run {
            self.authorizationStatus = initialAuthorizationStatus
        }
        CameraDebugLogger.log("authorizationStatus=\(CameraDebugLogger.authorizationDescription(initialAuthorizationStatus))")

        switch initialAuthorizationStatus {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            let updatedAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            await MainActor.run {
                self.authorizationStatus = updatedAuthorizationStatus
            }
            CameraDebugLogger.log("requestAccess result=\(granted) statusNow=\(CameraDebugLogger.authorizationDescription(updatedAuthorizationStatus))")
            guard granted else {
                setupInProgress = false
                return
            }
            configureSession()
        case .authorized:
            configureSession()
        case .denied, .restricted:
            CameraDebugLogger.log("prepare blocked by authorization state")
        @unknown default:
            CameraDebugLogger.log("prepare blocked by unknown authorization state")
        }

        setupInProgress = false
    }

    func start() {
        let now = Date()
        if let lastStartRequest, now.timeIntervalSince(lastStartRequest) < 0.2 {
            CameraDebugLogger.log("start skipped due to debounce")
            return
        }
        self.lastStartRequest = now

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else {
                CameraDebugLogger.log("start skipped; session not configured")
                return
            }
            guard !self.session.isRunning else {
                CameraDebugLogger.log("start skipped; already running")
                return
            }
            CameraDebugLogger.log("session.startRunning")
            self.session.startRunning()
            self.publishOnMain {
                self.isRunning = self.session.isRunning
            }
        }
    }

    func stop() {
        let now = Date()
        if let lastStopRequest, now.timeIntervalSince(lastStopRequest) < 0.2 {
            CameraDebugLogger.log("stop skipped due to debounce")
            return
        }
        lastStopRequest = now

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                CameraDebugLogger.log("stop skipped; already stopped")
                return
            }
            CameraDebugLogger.log("session.stopRunning")
            self.session.stopRunning()
            self.publishOnMain {
                self.isRunning = self.session.isRunning
            }
        }
    }

    func capturePhoto(_ completion: @escaping (Data?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured else {
                CameraDebugLogger.log("capture blocked; session not configured")
                self.publishOnMain { completion(nil) }
                return
            }

            guard self.session.outputs.contains(where: { $0 === self.output }) else {
                CameraDebugLogger.log("capture blocked; photo output missing from session")
                self.publishOnMain { completion(nil) }
                return
            }

            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            let maxQuality = self.output.maxPhotoQualityPrioritization
            let desiredQuality: AVCapturePhotoOutput.QualityPrioritization = .quality
            let finalQuality = Self.clampedQualityPrioritization(desired: desiredQuality, max: maxQuality)
            settings.photoQualityPrioritization = finalQuality
            print("[Camera] maxQuality=\(maxQuality) desired=\(desiredQuality) final=\(settings.photoQualityPrioritization)")
            self.pendingCaptures[settings.uniqueID] = completion
            CameraDebugLogger.log("capturePhoto requested uniqueID=\(settings.uniqueID)")
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private static func clampedQualityPrioritization(
        desired: AVCapturePhotoOutput.QualityPrioritization,
        max: AVCapturePhotoOutput.QualityPrioritization
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        switch max {
        case .speed:
            return .speed
        case .balanced:
            return desired == .quality ? .balanced : desired
        case .quality:
            return desired
        @unknown default:
            return .speed
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            CameraDebugLogger.log("session configuration begin")
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            let selectedDevice = CameraDeviceSelector.selectCamera(preferred: .front)
            guard let selectedDevice else {
                self.session.commitConfiguration()
                CameraDebugLogger.log("session configuration failed; no camera device")
                self.isConfigured = false
                self.publishOnMain {
                    self.unavailableMessage = "Camera not available on this device."
                    self.lastError = "Camera unavailable"
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: selectedDevice)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    CameraDebugLogger.log("session cannot add selected input")
                    self.isConfigured = false
                    self.publishOnMain {
                        self.lastError = "Could not access camera input"
                    }
                    return
                }
                self.session.addInput(input)
                CameraDebugLogger.log("session added input device=\(selectedDevice.localizedName)")
            } catch {
                self.session.commitConfiguration()
                CameraDebugLogger.log("session failed to create input error=\(error.localizedDescription)")
                self.isConfigured = false
                self.publishOnMain {
                    self.lastError = "Could not access camera"
                }
                return
            }

            guard self.session.canAddOutput(self.output) else {
                self.session.commitConfiguration()
                CameraDebugLogger.log("session cannot add AVCapturePhotoOutput")
                self.isConfigured = false
                self.publishOnMain {
                    self.lastError = "Could not configure photo output"
                }
                return
            }
            self.session.addOutput(self.output)
            self.output.isHighResolutionCaptureEnabled = true
            CameraDebugLogger.log("session added AVCapturePhotoOutput")

            self.session.commitConfiguration()
            self.installRuntimeObserversIfNeeded()
            CameraDebugLogger.log("session configuration commit complete")
            self.isConfigured = true

            self.publishOnMain {
                self.unavailableMessage = nil
                self.lastError = nil
            }
        }
    }

    private func installRuntimeObserversIfNeeded() {
        guard runtimeObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default

        let runtimeErrorToken = center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleRuntimeError(notification)
        }

        let interruptedToken = center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { notification in
            CameraDebugLogger.log("runtime interrupted userInfo=\(notification.userInfo ?? [:])")
        }

        let interruptionEndedToken = center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: nil
        ) { notification in
            CameraDebugLogger.log("runtime interruption ended userInfo=\(notification.userInfo ?? [:])")
        }

        runtimeObserverTokens = [runtimeErrorToken, interruptedToken, interruptionEndedToken]
    }

    private func handleRuntimeError(_ notification: Notification) {
        let nsError = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let domain = nsError?.domain ?? "unknown"
        let code = nsError?.code ?? -1
        CameraDebugLogger.log("runtime error domain=\(domain) code=\(code) userInfo=\(notification.userInfo ?? [:])")

        publishOnMain {
            self.lastError = "Camera runtime error (\(code)). Retrying…"
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if let lastRecoveryAttempt, now.timeIntervalSince(lastRecoveryAttempt) < 3 {
                CameraDebugLogger.log("runtime recovery throttled")
                return
            }

            self.lastRecoveryAttempt = now
            CameraDebugLogger.log("runtime recovery started")
            self.session.stopRunning()
            self.isConfigured = false
            self.configureSession()
            self.start()
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            CameraDebugLogger.log("didFinishProcessingPhoto error=\(error.localizedDescription)")
        }

        let data = photo.fileDataRepresentation()
        let uniqueID = photo.resolvedSettings.uniqueID

        self.sessionQueue.async { [weak self] in
            guard let self else { return }
            let completion = self.pendingCaptures.removeValue(forKey: uniqueID)
            self.publishOnMain {
                completion?(data)
            }
        }
    }
}

private enum CameraDeviceSelector {
    private static let discoveryTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
    ]

    static func selectCamera(preferred: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes,
            mediaType: .video,
            position: .unspecified
        )

        CameraDebugLogger.logDiscoveredDevices(discoverySession.devices)

        if preferred == .front,
           let front = discoverySession.devices.first(where: { $0.position == .front && $0.deviceType == .builtInWideAngleCamera }) {
            CameraDebugLogger.logSelectedDevice(front, reason: "preferred front wide-angle")
            return front
        }

        if let back = discoverySession.devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) {
            CameraDebugLogger.logSelectedDevice(back, reason: "fallback back wide-angle")
            return back
        }

        CameraDebugLogger.log("no wide-angle camera discovered")
        return nil
    }
}

private enum CameraDebugLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[Camera] \(message)")
        #endif
    }

    static func logDiscoveredDevices(_ devices: [AVCaptureDevice]) {
        if devices.isEmpty {
            log("discovered=[]")
            return
        }
        let descriptions = devices.map { device in
            "name=\(device.localizedName) type=\(device.deviceType.rawValue) position=\(positionDescription(device.position)) id=\(device.uniqueID)"
        }
        log("discovered=[\(descriptions.joined(separator: " | "))]")
    }

    static func logSelectedDevice(_ device: AVCaptureDevice, reason: String) {
        log("selectedDevice name=\(device.localizedName) type=\(device.deviceType.rawValue) position=\(positionDescription(device.position)) id=\(device.uniqueID) reason=\(reason)")
    }

    static func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static func positionDescription(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }
}
