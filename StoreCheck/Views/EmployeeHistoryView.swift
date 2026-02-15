import SwiftUI

struct EmployeeHistoryView: View {
    @StateObject private var vm = EmployeeHistoryViewModel(
        authService: AppContainer.shared.authService as! AuthService,
        checkInRepository: AppContainer.shared.checkInRepository
    )

    var body: some View {
        NavigationStack {
            List(vm.checkIns) { item in
                VStack(alignment: .leading) {
                    Text(item.storeName).font(.headline)
                    Text(item.checkInTime.formatted(date: .abbreviated, time: .shortened))
                    Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("History")
            .task { await vm.load() }
        }
    }
}
