import SwiftUI

struct EmployeeTabView: View {
    let container: AppContainer

    var body: some View {
        TabView {
            EmployeeDashboardView(
                authService: container.authService,
                storeRepository: container.storeRepository,
                checkInService: container.checkInService,
                checkInRepository: container.checkInRepository,
                locationService: container.locationService
            )
            .tabItem { Label("Shift", systemImage: "location.circle.fill") }

            EmployeeHistoryView(
                authService: container.authService,
                checkInRepository: container.checkInRepository,
                csvExporter: container.csvExporter
            )
            .tabItem { Label("History", systemImage: "clock.badge.checkmark") }

            EmployeeSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(DS.Colors.primary)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.white.opacity(0.92), for: .tabBar)
    }
}
