import SwiftUI

struct ManagerDashboardView: View {
    @StateObject private var vm = ManagerDashboardViewModel(checkInRepository: AppContainer.shared.checkInRepository)

    var body: some View {
        NavigationStack {
            List(vm.checkIns) { item in
                VStack(alignment: .leading) {
                    Text("\(item.employeeName) @ \(item.storeName)")
                    Text(item.checkInTime.formatted(date: .omitted, time: .shortened))
                    Text(item.status.rawValue.capitalized)
                        .foregroundStyle(item.status == .approved ? .green : .red)
                }
            }
            .navigationTitle("Today Check-ins")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: AppContainer.shared.csvExporter.generateCSV(from: vm.checkIns) ?? URL(fileURLWithPath: "")) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .task { await vm.load() }
        }
    }
}
