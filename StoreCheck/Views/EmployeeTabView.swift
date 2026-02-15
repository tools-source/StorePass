import SwiftUI

struct EmployeeTabView: View {
    let container: AppContainer

    var body: some View {
        TabView {
            EmployeeDashboardView(
                authService: container.authService,
                storeRepository: container.storeRepository,
                checkInService: container.checkInService,
                locationService: container.locationService
            )
            .tabItem { Label("Home", systemImage: "house") }

            EmployeeHistoryView(
                authService: container.authService,
                checkInRepository: container.checkInRepository
            )
            .tabItem { Label("History", systemImage: "clock") }

            EmployeeSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
