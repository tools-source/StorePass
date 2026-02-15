import SwiftUI

struct EmployeeHistoryView: View {
    @StateObject private var vm = EmployeeHistoryViewModel(
        authService: AppContainer.shared.authService,
        checkInRepository: AppContainer.shared.checkInRepository
    )

    var body: some View {
        CheckInHistoryView(viewModel: vm)
    }
}

struct CheckInHistoryView: View {
    @ObservedObject var viewModel: EmployeeHistoryViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.checkIns) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.storeName).font(.headline)
                    Text(item.checkInTime.formatted(date: .abbreviated, time: .shortened))
                    Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(DS.Colors.card)
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-in History")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}
