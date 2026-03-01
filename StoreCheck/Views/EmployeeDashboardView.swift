import SwiftUI
import UIKit

struct EmployeeDashboardView: View {
    @StateObject private var vm: EmployeeDashboardViewModel

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol,
        imageUploadService: ImageUploadServiceProtocol
    ) {
        _vm = StateObject(wrappedValue: EmployeeDashboardViewModel(
            authService: authService,
            storeRepository: storeRepository,
            checkInService: checkInService,
            checkInRepository: checkInRepository,
            locationService: locationService,
            imageUploadService: imageUploadService
        ))
    }

    var body: some View {
        EmployeeHomeView(viewModel: vm)
    }
}

struct EmployeeHomeView: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    @State private var pendingLeaveStore: Store?
    @State private var showManageStores = false
    @State private var isLocationExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    JoinStoreCard(viewModel: viewModel)

                    currentStoreCard

                    if !viewModel.stores.isEmpty {
                        statusCard

                        Button(viewModel.activeSession == nil ? "Check In" : "Check Out") {
                            if viewModel.activeSession == nil {
                                viewModel.beginCheckInPhotoCapture()
                            } else {
                                viewModel.beginCheckOutPhotoCapture()
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.activeSession == nil && viewModel.blockedReason != nil)

                        if let reason = viewModel.blockedReason {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(DS.Spacing.l)
            }
            .navigationTitle("Employee")
            .task { await viewModel.load() }
            .refreshable { viewModel.refreshLocation() }
            .alert("Check-in", isPresented: $viewModel.checkInSuccessBanner) {
                Button("Done", role: .cancel) { }
            } message: {
                Text("Check-in submitted successfully.")
            }
            .alert("Store access", isPresented: Binding(get: {
                viewModel.errorMessage != nil
            }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert(
                "Leave store",
                isPresented: Binding(
                    get: { pendingLeaveStore != nil },
                    set: { newValue in
                        if !newValue { pendingLeaveStore = nil }
                    }
                )
            ) {
                Button("Leave", role: .destructive) {
                    if let store = pendingLeaveStore {
                        Task { await viewModel.leaveStore(storeId: store.id) }
                    }
                    pendingLeaveStore = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingLeaveStore = nil
                }
            } message: {
                if let store = pendingLeaveStore {
                    Text("Leave '\(store.name)'? You may need a new code to rejoin.")
                }
            }
            .sheet(isPresented: $showManageStores) {
                NavigationStack {
                    List {
                        if viewModel.stores.isEmpty {
                            Text("No assigned stores yet. Join with a store code.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.stores) { store in
                                HStack(spacing: 10) {
                                    Image(systemName: viewModel.selectedStore?.id == store.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(viewModel.selectedStore?.id == store.id ? .blue : .secondary)
                                    Text(store.name)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Leave", role: .destructive) {
                                        pendingLeaveStore = store
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Manage Stores")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showManageStores = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $viewModel.isShowingCamera) {
                CameraCaptureSheet(
                    isPresented: $viewModel.isShowingCamera,
                    title: viewModel.pendingPhotoPurpose == .checkOut ? "Check Out Photo" : "Check In Photo"
                ) { image in
                    Task {
                        await viewModel.processCapturedPhoto(image)
                        if viewModel.checkInSuccessBanner {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                }
            }
        }
    }

    private var currentStoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Current Store")
                    .font(.headline)
                Spacer()
                if !viewModel.stores.isEmpty {
                    Button("Manage") {
                        showManageStores = true
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if viewModel.stores.isEmpty {
                Text("No assigned stores yet. Join with a store code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.stores) { store in
                        HStack(spacing: 10) {
                            Image(systemName: viewModel.selectedStore?.id == store.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(viewModel.selectedStore?.id == store.id ? .blue : .secondary)
                            Text(store.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectStore(withId: store.id)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(DS.Colors.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.separator.opacity(0.35), lineWidth: 1))
                    }
                }
            }
        }
        .cardStyle()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isLocationExpanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "location.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 30, height: 30)
                            .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Location")
                                .font(.headline)
                            Text(statusPrimary)
                                .font(.subheadline.weight(.semibold))
                            if let secondary = statusSecondary {
                                Text(secondary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 8) {
                            statusChip
                            Image(systemName: isLocationExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if isLocationExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            Divider().opacity(0.25)
                            locationDetailRow(label: "Distance", value: distanceText)
                            if let accuracyText {
                                locationDetailRow(label: "Accuracy", value: accuracyText)
                            }
                            locationDetailRow(label: "Last updated", value: lastUpdatedText)
                            Button("Refresh location") {
                                viewModel.refreshLocation()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.blue)
                            .frame(maxWidth: .infinity)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private var statusChip: some View {
        let chip = statusChipStyle
        return Text(chip.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(chip.foreground)
            .background(chip.background, in: Capsule())
    }

    private var statusChipStyle: (text: String, foreground: Color, background: Color) {
        switch viewModel.locationStatus {
        case .inRange:
            ("In range", .green.opacity(0.95), .green.opacity(0.18))
        case .outOfRange:
            ("Out of range", .red.opacity(0.95), .red.opacity(0.18))
        default:
            ("Locating", DS.Colors.textSecondary, DS.Colors.background)
        }
    }

    private func locationDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }

    private var distanceText: String {
        switch viewModel.locationStatus {
        case .inRange(let distance), .outOfRange(let distance):
            "\(Int(distance))m"
        default:
            "Unknown"
        }
    }

    private var accuracyText: String? {
        switch viewModel.locationStatus {
        case .lowAccuracy(let accuracy):
            "±\(Int(accuracy))m"
        case .inRange, .outOfRange:
            "Good"
        default:
            nil
        }
    }

    private var lastUpdatedText: String {
        guard let updatedAt = viewModel.lastLocationRefreshAt else {
            return "Updated just now"
        }
        return updatedAt.formatted(date: .omitted, time: .standard)
    }

    private var statusPrimary: String {
        switch viewModel.locationStatus {
        case .inRange(let distance):
            "In range • \(Int(distance))m"
        case .outOfRange(let distance):
            "Out of range • \(Int(distance))m"
        default:
            "Locating • \(distanceText)"
        }
    }

    private var statusSecondary: String? {
        switch viewModel.locationStatus {
        case .inRange, .outOfRange:
            "Accuracy: Good"
        case .lowAccuracy(let accuracy):
            "Accuracy: ±\(Int(accuracy))m"
        case .permissionDenied:
            "Accuracy: Permission denied"
        case .locationUnavailable:
            "Accuracy: Location unavailable"
        case .preciseLocationRequired:
            "Accuracy: Precise required"
        case .unknown:
            "Accuracy: Resolving"
        }
    }
}

private struct JoinStoreCard: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Join Store")
                .font(.headline)
            TextField("Enter store code", text: $viewModel.joinCodeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(12)
                .background(DS.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Join") {
                Task {
                    await viewModel.joinStoreByCode()
                }
            }
            .buttonStyle(PrimaryButtonStyle())

            if let joinStatusMessage = viewModel.joinStatusMessage {
                Text(joinStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}
