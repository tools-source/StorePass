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

struct EmployeeHomeView: View {
    @ObservedObject var viewModel: EmployeeDashboardViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    JoinStoreCard(viewModel: viewModel)

                    currentStoreCard

                    if !viewModel.stores.isEmpty {
                        statusCard

                        Button(viewModel.activeSession == nil ? "Check In" : "Check Out") {
                            Task {
                                if viewModel.activeSession == nil {
                                    await viewModel.checkIn()
                                } else {
                                    await viewModel.checkOut()
                                }
                                if viewModel.checkInSuccessBanner {
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
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
        }
    }

    private var currentStoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Store")
                .font(.headline)

            if viewModel.stores.isEmpty {
                Text("No assigned stores yet. Join with a store code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "building.2.crop.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    Picker("Assigned store", selection: Binding(get: {
                        viewModel.selectedStore?.id ?? ""
                    }, set: { id in
                        viewModel.selectStore(withId: id)
                    })) {
                        ForEach(viewModel.stores) { store in
                            Text(store.name).tag(store.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .cardStyle()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundStyle(.blue)
                Text("Location Status")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusPrimary)
                    .font(.subheadline.weight(.semibold))
                if let secondary = statusSecondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Refresh location") {
                viewModel.refreshLocation()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .cardStyle()
    }

    private var statusPrimary: String {
        switch viewModel.locationStatus {
        case .inRange(let distance):
            "In range • \(Int(distance))m"
        case .outOfRange(let distance):
            "Out of range • \(Int(distance))m"
        case .lowAccuracy:
            "Location accuracy is low"
        case .permissionDenied:
            "Permission denied"
        case .locationUnavailable:
            "Location unavailable"
        case .preciseLocationRequired:
            "Precise location required"
        case .unknown:
            "Resolving location"
        }
    }

    private var statusSecondary: String? {
        switch viewModel.locationStatus {
        case .inRange:
            "Accuracy: Good"
        case .outOfRange:
            "Accuracy: Good"
        case .lowAccuracy(let accuracy):
            "Accuracy: ±\(Int(accuracy))m"
        case .permissionDenied,
             .locationUnavailable,
             .preciseLocationRequired,
             .unknown:
            nil
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
