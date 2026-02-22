import SwiftUI

struct ManagerDashboardView: View {
    @StateObject private var vm: ManagerDashboardViewModel
    @EnvironmentObject private var authViewModel: AuthViewModel
    private let csvExporter: CSVExportServiceProtocol
    let isActiveTab: Bool

    init(checkInRepository: CheckInRepositoryProtocol, csvExporter: CSVExportServiceProtocol, isActiveTab: Bool) {
        _vm = StateObject(wrappedValue: ManagerDashboardViewModel(checkInRepository: checkInRepository))
        self.csvExporter = csvExporter
        self.isActiveTab = isActiveTab
    }

    var body: some View {
        ManagerCheckinsView(
            viewModel: vm,
            csvExporter: csvExporter,
            isActiveTab: isActiveTab,
            isManager: authViewModel.currentUser?.role == .manager
        )
    }
}

private struct ManagerCheckinsView: View {
    @ObservedObject var viewModel: ManagerDashboardViewModel
    let csvExporter: CSVExportServiceProtocol
    let isActiveTab: Bool
    let isManager: Bool

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
                    if let url = csvExporter.generateCSV(from: viewModel.checkIns, filePrefix: "checkins_manager") {
                        ShareLink(item: url) { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .onAppear {
                viewModel.updateListenerState(isDashboardVisible: isActiveTab, isManager: isManager, source: "ManagerDashboardView.onAppear")
            }
            .onDisappear {
                viewModel.updateListenerState(isDashboardVisible: false, isManager: isManager, source: "ManagerDashboardView.onDisappear")
            }
            .onChange(of: isActiveTab) { _, active in
                viewModel.updateListenerState(isDashboardVisible: active, isManager: isManager, source: "ManagerDashboardView.onChange(isActiveTab)")
            }
            .onChange(of: isManager) { _, roleIsManager in
                viewModel.updateListenerState(isDashboardVisible: isActiveTab, isManager: roleIsManager, source: "ManagerDashboardView.onChange(isManager)")
            }
            .alert("Check-ins", isPresented: Binding(get: { viewModel.checkinError != nil }, set: { _ in viewModel.checkinError = nil })) {
                Button("OK", role: .cancel) { viewModel.checkinError = nil }
            } message: {
                Text(viewModel.checkinError ?? "")
            }
        }
    }
}
