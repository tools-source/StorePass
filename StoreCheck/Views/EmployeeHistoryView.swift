import SwiftUI

struct EmployeeHistoryView: View {
    @StateObject private var vm: EmployeeHistoryViewModel

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol) {
        _vm = StateObject(wrappedValue: EmployeeHistoryViewModel(
            authService: authService,
            checkInRepository: checkInRepository
        ))
    }

    var body: some View {
        CheckInHistoryView(viewModel: vm)
    }
}

struct CheckInHistoryView: View {
    @ObservedObject var viewModel: EmployeeHistoryViewModel

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                if viewModel.checkIns.isEmpty, viewModel.errorMessage == nil {
                    Text("No check-ins yet. Make a check-in to see history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.checkIns) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.storeName).font(.headline)
                        Text(item.checkInTime.formatted(date: .abbreviated, time: .shortened))
                        Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(DS.Colors.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-in History")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}
