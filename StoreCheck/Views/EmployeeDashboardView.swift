import SwiftUI
import UIKit

struct EmployeeDashboardView: View {
    @StateObject private var vm: EmployeeDashboardViewModel

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        locationService: LocationServiceProtocol
    ) {
        _vm = StateObject(wrappedValue: EmployeeDashboardViewModel(
            authService: authService,
            storeRepository: storeRepository,
            checkInService: checkInService,
            locationService: locationService
        ))
    }

    var body: some View {
        EmployeeHomeView(viewModel: vm)
    }
}

struct EmployeeHomeView: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    JoinStoreCard(viewModel: viewModel)

                    if viewModel.stores.isEmpty {
                        Text("No assigned stores yet. Contact your manager.")
                            .cardStyle()
                    } else {
                        Picker("Assigned store", selection: Binding(get: {
                            viewModel.selectedStore?.id ?? ""
                        }, set: { id in
                            viewModel.selectedStore = viewModel.stores.first(where: { $0.id == id })
                            viewModel.refreshLocation()
                        })) {
                            ForEach(viewModel.stores) { store in
                                Text(store.name).tag(store.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .cardStyle()

                        statusCard

                        Button("Check In") {
                            Task {
                                await viewModel.checkIn()
                                if viewModel.checkInSuccessBanner {
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(viewModel.blockedReason != nil)

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
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location status").font(.headline)
            switch viewModel.locationStatus {
            case .inRange(let distance):
                Text("In range • \(Int(distance))m")
                Text("Accuracy good")
            case .outOfRange(let distance):
                Text("Out of range • \(Int(distance))m")
            case .lowAccuracy(let accuracy):
                Text("Accuracy ±\(Int(accuracy))m")
            case .permissionDenied:
                Text("Permission denied")
            case .locationUnavailable:
                Text("Location unavailable")
            case .preciseLocationRequired:
                Text("Precise location required")
            case .unknown:
                Text("Resolving location")
            }

            Button("Refresh location") {
                viewModel.refreshLocation()
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
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
