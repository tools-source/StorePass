import AVFoundation
import SwiftUI
import UIKit

struct EmployeeDashboardView: View {
    @StateObject private var vm: EmployeeDashboardViewModel

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol
    ) {
        _vm = StateObject(wrappedValue: EmployeeDashboardViewModel(
            authService: authService,
            storeRepository: storeRepository,
            checkInService: checkInService,
            checkInRepository: checkInRepository,
            locationService: locationService
        ))
    }

    var body: some View {
        EmployeeHomeView(viewModel: vm)
    }
}

struct EmployeeCheckInView: View {
    @StateObject private var vm: EmployeeDashboardViewModel

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol
    ) {
        _vm = StateObject(wrappedValue: EmployeeDashboardViewModel(
            authService: authService,
            storeRepository: storeRepository,
            checkInService: checkInService,
            checkInRepository: checkInRepository,
            locationService: locationService
        ))
    }

    var body: some View {
        EmployeeHomeView(viewModel: vm)
    }
}

private struct EmployeeHomeView: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    @State private var pendingCameraAction: EmployeeDashboardViewModel.AttendanceAction?
    @State private var showLeaveConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        ScreenHeader(
                            title: "My Shift",
                            subtitle: "Check location, then check in or out.",
                            icon: "location.circle"
                        )

                        shiftStatusCard
                        actionCard
                        membershipCard
                        todaySummaryCard
                        sessionsCard

                        if let error = viewModel.errorMessage {
                            BannerView(text: error, isError: true)
                        }
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
            }
            .navigationTitle("Shift")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.refreshLocation()
                        Task { await viewModel.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await viewModel.load()
            }
            .refreshable {
                await viewModel.load()
            }
            .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                Task { await viewModel.load() }
            }
            .fullScreenCover(item: $pendingCameraAction) { action in
                FrontCameraCaptureView(
                    title: action == .checkIn ? "Capture Check-In Photo" : "Capture Check-Out Photo",
                    onCancel: { pendingCameraAction = nil },
                    onCapture: { imageData in
                        pendingCameraAction = nil
                        Task {
                            await viewModel.performAttendanceAction(action, photoData: imageData)
                            await viewModel.load()
                        }
                    }
                )
            }
            .alert("Leave Store?", isPresented: $showLeaveConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Leave", role: .destructive) {
                    guard let store = viewModel.selectedStore else { return }
                    Task {
                        await viewModel.leaveStore(storeId: store.id)
                    }
                }
            } message: {
                Text("You will no longer be able to check in or out for this store.")
            }
            .overlay {
                if viewModel.isCheckInInProgress || viewModel.isCheckOutInProgress {
                    LoadingOverlay(message: "Submitting attendance...")
                }
            }
        }
    }

    private var shiftStatusCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.selectedStore?.name ?? "No selected store")
                            .font(DS.Typography.title)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)

                        Text(viewModel.selectedStore?.address ?? "Join a store to start attendance")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    if viewModel.activeSession == nil {
                        StatBadge(style: .open, text: "Not checked in")
                    } else {
                        StatBadge(style: .closed, text: "Checked in")
                    }
                }

                HStack(spacing: DS.Spacing.s) {
                    StatBadge(
                        style: viewModel.locationStatus.isInside ? .inside : .outside,
                        text: viewModel.locationStatus.statusText
                    )

                    Spacer()

                    Text("Updated \(viewModel.lastLocationRefreshAt?.formatted(date: .omitted, time: .shortened) ?? "—")")
                        .font(DS.Typography.micro)
                        .foregroundStyle(DS.Colors.textSecondary)
                }

                if let blocked = viewModel.blockedReason {
                    Text(blocked)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(
                    title: "Attendance Action",
                    subtitle: "Front-camera photo is required each time.",
                    icon: "camera.viewfinder"
                )

                Button {
                    pendingCameraAction = viewModel.activeSession == nil ? .checkIn : .checkOut
                } label: {
                    HStack(spacing: DS.Spacing.s) {
                        Image(systemName: viewModel.activeSession == nil ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                        Text(viewModel.activeSession == nil ? "Check In" : "Check Out")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Spacing.m)
                    .frame(minHeight: 66)
                    .background(DS.Colors.primaryGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: DS.Colors.primary.opacity(0.25), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.stores.isEmpty || viewModel.selectedStore == nil)
                .opacity((viewModel.stores.isEmpty || viewModel.selectedStore == nil) ? 0.5 : 1)

                Text("Gallery upload is disabled. Capture happens with front camera only.")
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    private var membershipCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(
                    title: "Store Membership",
                    subtitle: "Join with code or switch your assigned store.",
                    icon: "building.2"
                )

                if viewModel.stores.isEmpty {
                    Text("No active store assignment")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    Picker("Store", selection: Binding(
                        get: { viewModel.selectedStore?.id ?? "" },
                        set: { viewModel.selectStore(withId: $0) }
                    )) {
                        ForEach(viewModel.stores) { store in
                            Text(store.name).tag(store.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Leave Selected Store", role: .destructive) {
                        showLeaveConfirmation = true
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(viewModel.selectedStore == nil)
                }

                HStack(spacing: DS.Spacing.s) {
                    TextField("Enter join code", text: $viewModel.joinCodeInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, DS.Spacing.s)
                        .frame(height: DS.Metrics.rowHeight)
                        .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button("Join") {
                        Task { await viewModel.joinStoreByCode() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 92)
                }

                if let joinMessage = viewModel.joinStatusMessage {
                    BannerView(text: joinMessage, isError: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var todaySummaryCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Today", subtitle: "Live shift totals", icon: "clock.badge.checkmark")

                HStack(spacing: DS.Spacing.s) {
                    MetricChip(
                        label: "Sessions",
                        value: "\(viewModel.todaysCheckIns.count)",
                        icon: "list.bullet"
                    )

                    MetricChip(
                        label: "Open",
                        value: viewModel.activeSession == nil ? "0" : "1",
                        icon: "record.circle"
                    )

                    MetricChip(
                        label: "Total",
                        value: DurationFormatter.clockString(from: viewModel.totalTodaySeconds),
                        icon: "hourglass.bottomhalf.filled"
                    )
                }
            }
        }
    }

    private var sessionsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Session Timeline", subtitle: "Most recent first", icon: "calendar.badge.clock")

                if viewModel.todaysCheckIns.isEmpty {
                    Text("No sessions yet today.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(viewModel.todaysCheckIns) { session in
                            HStack(alignment: .top, spacing: DS.Spacing.s) {
                                Circle()
                                    .fill(DS.Colors.primary.opacity(0.25))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.storeName)
                                        .font(DS.Typography.headline)
                                        .foregroundStyle(DS.Colors.textPrimary)

                                    Text("\(session.checkInTime.formatted(date: .omitted, time: .shortened)) → \(session.checkOutTime?.formatted(date: .omitted, time: .shortened) ?? "Open")")
                                        .font(DS.Typography.caption)
                                        .foregroundStyle(DS.Colors.textSecondary)
                                }

                                Spacer(minLength: 8)

                                Text(DurationFormatter.clockString(from: session.computedDurationSeconds ?? 0))
                                    .font(DS.Typography.mono.weight(.semibold))
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private final class FrontCameraCaptureController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var permissionGranted = false
    @Published var permissionDenied = false
    @Published var isConfigured = false
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()

    private var captureContinuation: CheckedContinuation<Data, Error>?

    func prepare() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            permissionGranted = true
            configureSessionIfNeeded()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    self.permissionDenied = !granted
                    if granted {
                        self.configureSessionIfNeeded()
                    }
                }
            }

        case .denied, .restricted:
            permissionDenied = true
            errorMessage = "Camera access is required for attendance photos. Enable Camera for StorePass in Settings."

        @unknown default:
            permissionDenied = true
            errorMessage = "Camera is unavailable on this device."
        }
    }

    func startSession() {
        guard isConfigured, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }

    func capturePhoto() async throws -> Data {
        guard permissionGranted else {
            throw CloudKitClientError.invalidData("Camera permission is required.")
        }

        if !session.isRunning {
            startSession()
        }

        return try await withCheckedThrowingContinuation { continuation in
            captureContinuation = continuation
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            captureContinuation?.resume(throwing: error)
            captureContinuation = nil
            return
        }

        guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
            captureContinuation?.resume(throwing: CloudKitClientError.invalidData("Failed to capture photo."))
            captureContinuation = nil
            return
        }

        captureContinuation?.resume(returning: data)
        captureContinuation = nil
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        defer {
            session.commitConfiguration()
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            errorMessage = "Front camera is unavailable on this device."
            permissionDenied = true
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            isConfigured = true
        } catch {
            errorMessage = "Failed to access camera hardware."
            permissionDenied = true
        }
    }
}

private struct FrontCameraCaptureView: View {
    let title: String
    let onCancel: () -> Void
    let onCapture: (Data) -> Void

    @StateObject private var controller = FrontCameraCaptureController()
    @State private var captureError: String?
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.permissionDenied {
                VStack(spacing: DS.Spacing.m) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(controller.errorMessage ?? "Camera permission is required.")
                        .font(DS.Typography.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Spacing.l)

                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Cancel", action: onCancel)
                        .buttonStyle(DestructiveButtonStyle())
                }
            } else {
                VStack(spacing: 0) {
                    CameraPreview(session: controller.session)
                        .overlay(alignment: .topLeading) {
                            Text(title)
                                .font(DS.Typography.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.42), in: Capsule())
                                .padding()
                        }

                    VStack(spacing: DS.Spacing.s) {
                        Text("Use front camera and keep your face clearly visible.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(.white.opacity(0.82))

                        HStack(spacing: DS.Spacing.m) {
                            Button("Cancel", action: onCancel)
                                .buttonStyle(SecondaryButtonStyle())

                            Button(isCapturing ? "Capturing..." : "Capture") {
                                Task {
                                    await capture()
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isCapturing)
                        }
                    }
                    .padding(DS.Spacing.m)
                    .background(Color.black)
                }
            }
        }
        .alert("Camera", isPresented: Binding(get: { captureError != nil }, set: { _ in captureError = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(captureError ?? "")
        }
        .onAppear {
            controller.prepare()
            controller.startSession()
        }
        .onDisappear {
            controller.stopSession()
        }
    }

    private func capture() async {
        isCapturing = true
        defer { isCapturing = false }

        do {
            let data = try await controller.capturePhoto()
            onCapture(data)
        } catch {
            captureError = error.localizedDescription
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private extension LocationCheckState {
    var isInside: Bool {
        if case .inRange = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .inRange(let distance):
            return "In range • \(Int(distance))m"
        case .outOfRange(let distance):
            return "Out of range • \(Int(distance))m"
        case .permissionDenied:
            return "Location permission needed"
        case .locationUnavailable:
            return "Location unavailable"
        case .preciseLocationRequired:
            return "Precise location required"
        case .lowAccuracy(let accuracy):
            return "Low accuracy ±\(Int(accuracy))m"
        case .unknown:
            return "Checking location..."
        }
    }
}

extension EmployeeDashboardViewModel.AttendanceAction: Identifiable {
    var id: Int {
        switch self {
        case .checkIn:
            return 1
        case .checkOut:
            return 2
        }
    }
}
