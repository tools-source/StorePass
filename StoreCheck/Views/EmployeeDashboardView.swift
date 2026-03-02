import SwiftUI

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
        EmployeeCheckInContentView(viewModel: vm)
    }
}

private struct EmployeeHomeView: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel
    @State private var showStoreSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    if viewModel.stores.isEmpty {
                        EmptyStateView(
                            icon: "building.2.crop.circle",
                            title: "No Store Assigned",
                            message: "Join a store to start tracking your shifts.",
                            ctaTitle: "Join Store"
                        ) {
                            showStoreSheet = true
                        }
                    } else {
                        todayCard
                        statsCard
                        Button(viewModel.activeSession == nil ? "Check In" : "Check Out") {
                            viewModel.activeSession == nil ? viewModel.beginCheckIn() : viewModel.beginCheckOut()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.isCheckInInProgress || viewModel.isCheckOutInProgress || (viewModel.activeSession == nil && viewModel.blockedReason != nil))
                    }
                }
                .padding(DS.Spacing.m)
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stores") { showStoreSheet = true }
                }
            }
            .task { await viewModel.load() }
            .refreshable { viewModel.refreshLocation() }
            .sheet(isPresented: $showStoreSheet) { JoinStoreSheet(viewModel: viewModel) }
            .overlay {
                if viewModel.isCheckInInProgress || viewModel.isCheckOutInProgress {
                    LoadingOverlay(message: "Confirming location…")
                }
            }
        }
    }

    private var todayCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("Today")
                    .font(DS.Typography.title)
                Text(viewModel.selectedStore?.name ?? "No store selected")
                    .font(DS.Typography.headline)
                Text(viewModel.activeSession == nil ? "Not checked in" : "Checked in since \(viewModel.activeSession?.checkInTime.formatted(date: .omitted, time: .shortened) ?? "")")
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack {
                    Text("Total time")
                    Spacer()
                    Text(DurationFormatter.clockString(from: viewModel.todaysCheckIns.compactMap(\.computedDurationSeconds).reduce(0,+)))
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Last status")
                    Spacer()
                    StatBadge(style: viewModel.locationStatus.isInside ? .inside : .outside)
                }
                if let reason = viewModel.blockedReason {
                    BannerView(text: reason, isError: true)
                }
            }
        }
    }
}

private struct EmployeeCheckInContentView: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    if viewModel.stores.isEmpty {
                        EmptyStateView(icon: "building.2", title: "No Stores", message: "Ask your manager for a join code to continue.")
                    } else {
                        JoinStoreSheet.storePicker(viewModel: viewModel)
                        CardView {
                            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                                Text("Location status")
                                StatBadge(style: viewModel.locationStatus.isInside ? .inside : .outside, text: viewModel.locationStatus.statusText)
                                Text("Tap the button below to verify your live location and register your \(viewModel.activeSession == nil ? "check-in" : "check-out").")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(viewModel.activeSession == nil ? "Check In" : "Check Out") {
                            viewModel.activeSession == nil ? viewModel.beginCheckIn() : viewModel.beginCheckOut()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        if let errorMessage = viewModel.errorMessage {
                            CardView {
                                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                                    Text("Need attention")
                                        .font(.headline)
                                    Text(errorMessage)
                                        .foregroundStyle(.secondary)
                                    Text("Try enabling location permission, moving closer to the store, or switching stores.")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding(DS.Spacing.m)
            }
            .navigationTitle("Check In")
            .task { await viewModel.load() }
            .overlay {
                if viewModel.isCheckInInProgress || viewModel.isCheckOutInProgress {
                    LoadingOverlay(message: "Submitting…")
                }
            }
        }
    }
}

private struct JoinStoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.m) {
                Self.storePicker(viewModel: viewModel)
                TextField("Enter join code", text: $viewModel.joinCodeInput)
                    .textInputAutocapitalization(.characters)
                    .padding()
                    .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Join Store") { Task { await viewModel.joinStoreByCode() } }
                    .buttonStyle(PrimaryButtonStyle())
                if let message = viewModel.joinStatusMessage { BannerView(text: message, isError: false) }
                Spacer()
            }
            .padding(DS.Spacing.m)
            .navigationTitle("Stores")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    static func storePicker(viewModel: EmployeeDashboardViewModel) -> some View {
        CardView {
            Picker("Store", selection: Binding(get: { viewModel.selectedStore?.id ?? "" }, set: { viewModel.selectStore(withId: $0) })) {
                ForEach(viewModel.stores) { store in
                    Text(store.name).tag(store.id)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private extension LocationCheckState {
    var isInside: Bool {
        if case .inRange = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .inRange(let d): return "Inside • \(Int(d))m"
        case .outOfRange(let d): return "Outside • \(Int(d))m"
        case .permissionDenied: return "Permission denied"
        case .lowAccuracy(let accuracy): return "Low accuracy ±\(Int(accuracy))m"
        case .unknown: return "Checking…"
        }
    }
}
