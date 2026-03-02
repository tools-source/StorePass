import SwiftUI

struct ManagerHomeView: View {
    let container: AppContainer

    private enum ManagerTab: Hashable {
        case dashboard, stores, employees, checkIns, settings
    }

    @State private var selectedTab: ManagerTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            ManagerDashboardView(
                checkInRepository: container.checkInRepository,
                csvExporter: container.csvExporter,
                isActiveTab: selectedTab == .dashboard
            )
            .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }
            .tag(ManagerTab.dashboard)

            ManageStoresView(repository: container.storeRepository)
                .tabItem { Label("Stores", systemImage: "building.2.fill") }
                .tag(ManagerTab.stores)

            EmployeeManagementView(
                employeeRepository: container.employeeManagementRepository,
                authRepository: container.authRepository
            )
            .tabItem { Label("Employees", systemImage: "person.3.fill") }
            .tag(ManagerTab.employees)

            ManagerCheckInsView(
                storeRepository: container.storeRepository,
                checkInRepository: container.checkInRepository,
                authRepository: container.authRepository,
                csvExporter: container.csvExporter
            )
            .tabItem { Label("Check-ins", systemImage: "checkmark.circle.fill") }
            .tag(ManagerTab.checkIns)

            AccountSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(ManagerTab.settings)
        }
    }
}

struct ManagerTabView: View {
    let container: AppContainer

    var body: some View {
        ManagerHomeView(container: container)
    }
}
