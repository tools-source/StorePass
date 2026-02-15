import SwiftUI

struct ManagerDashboardView: View {
    @StateObject private var vm = ManagerDashboardViewModel(checkInRepository: AppContainer.shared.checkInRepository)

    var body: some View {
        ManagerHomeView(viewModel: vm)
    }
}

struct ManagerHomeView: View {
    @ObservedObject var viewModel: ManagerDashboardViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.checkIns) { item in
                VStack(alignment: .leading) {
                    Text("\(item.employeeName) • \(item.storeName)").font(.headline)
                    Text(item.checkInTime.formatted(date: .omitted, time: .shortened))
                    Text(item.status.rawValue.capitalized)
                        .foregroundStyle(item.status == .approved ? .green : .red)
                }
                .listRowBackground(DS.Colors.card)
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Today Check-ins")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = AppContainer.shared.csvExporter.generateCSV(from: viewModel.checkIns) {
                        ShareLink(item: url) { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}
