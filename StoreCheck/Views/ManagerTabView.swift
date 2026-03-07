import SwiftUI

struct ManagerHomeView: View {
    let container: AppContainer

    private enum ManagerTab: Hashable {
        case stores
        case employees
        case attendance
        case settings
    }

    @State private var selectedTab: ManagerTab = .stores

    var body: some View {
        TabView(selection: $selectedTab) {
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
            .tabItem { Label("Attendance", systemImage: "checklist.checked") }
            .tag(ManagerTab.attendance)

            AccountSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(ManagerTab.settings)
        }
        .tint(DS.Colors.primary)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(DS.Colors.tabBarBackground, for: .tabBar)
    }
}

struct ManagerTabView: View {
    let container: AppContainer

    var body: some View {
        ManagerHomeView(container: container)
    }
}
