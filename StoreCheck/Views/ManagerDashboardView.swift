import SwiftUI

struct ManagerDashboardView: View {
    @StateObject private var vm: ManagerDashboardViewModel
    private let csvExporter: CSVExportServiceProtocol

    init(checkInRepository: CheckInRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        _vm = StateObject(wrappedValue: ManagerDashboardViewModel(checkInRepository: checkInRepository))
        self.csvExporter = csvExporter
    }

    var body: some View {
        ManagerHomeView(viewModel: vm, csvExporter: csvExporter)
    }
}

struct ManagerHomeView: View {
    @ObservedObject var viewModel: ManagerDashboardViewModel
    let csvExporter: CSVExportServiceProtocol

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
                    if let url = csvExporter.generateCSV(from: viewModel.checkIns) {
                        ShareLink(item: url) { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .onAppear { viewModel.startListening() }
            .onDisappear { viewModel.stopListening() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in viewModel.refreshListener() }
            .onChange(of: viewModel.selectedStatus) { _, _ in viewModel.refreshListener() }
            .onChange(of: viewModel.selectedDate) { _, _ in viewModel.refreshListener() }
            .alert("Check-ins", isPresented: Binding(get: { viewModel.checkinError != nil }, set: { _ in viewModel.checkinError = nil })) {
                Button("OK", role: .cancel) { viewModel.checkinError = nil }
            } message: {
                Text(viewModel.checkinError ?? "")
            }
        }
    }
}
