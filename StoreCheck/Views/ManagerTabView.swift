import SwiftUI

struct ManagerHomeView: View {
    let container: AppContainer

    private enum ManagerTab: Hashable {
        case stores
        case employees
        case checkIns
        case settings
    }

    @State private var selectedTab: ManagerTab = .stores

    var body: some View {
        TabView(selection: $selectedTab) {
            ManageStoresView(repository: container.storeRepository)
                .tabItem { Label("Stores", systemImage: "building.2") }
                .tag(ManagerTab.stores)

            EmployeeManagementView(
                employeeRepository: container.employeeManagementRepository,
                authRepository: container.authRepository
            )
            .tabItem { Label("Employees", systemImage: "person.3") }
            .tag(ManagerTab.employees)

            ManagerCheckInsView(
                storeRepository: container.storeRepository,
                checkInRepository: container.checkInRepository,
                authRepository: container.authRepository
            )
            .tabItem { Label("Check-ins", systemImage: "checkmark.circle") }
            .tag(ManagerTab.checkIns)

            AccountSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
