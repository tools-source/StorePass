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
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    kpis
                    CardView {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            Text("Live activity").font(.headline)
                            ForEach(vm.checkIns.prefix(15)) { item in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.employeeName).font(.subheadline.weight(.semibold))
                                        Text(item.checkInTime.formatted(date: .omitted, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatBadge(style: item.verifyInInside == true ? .inside : .outside)
                                    StatBadge(style: item.checkOutTime == nil ? .open : .closed)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(DS.Spacing.m)
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = csvExporter.generateCSV(from: vm.checkIns, filePrefix: "manager_dashboard") {
                        ShareLink(item: url)
                    }
                }
            }
            .onAppear { vm.updateListenerState(isDashboardVisible: isActiveTab, isManager: authViewModel.currentUser?.role == .manager, source: "dashboard") }
            .onChange(of: isActiveTab) { _, active in
                vm.updateListenerState(isDashboardVisible: active, isManager: authViewModel.currentUser?.role == .manager, source: "dashboard_tab")
            }
        }
    }

    private var kpis: some View {
        let open = vm.checkIns.filter { $0.checkOutTime == nil }.count
        let exceptions = vm.checkIns.filter { $0.status == .rejected || $0.verifyInInside == false }.count
        let totalHours = vm.checkIns.compactMap(\.computedDurationSeconds).reduce(0,+) / 3600

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.s) {
            kpi("Checked in", "\(open)")
            kpi("Check-ins", "\(vm.checkIns.count)")
            kpi("Hours", "\(totalHours)h")
            kpi("Exceptions", "\(exceptions)")
        }
    }

    private func kpi(_ title: String, _ value: String) -> some View {
        CardView {
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
