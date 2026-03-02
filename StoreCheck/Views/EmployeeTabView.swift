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
            .tabItem { Label("Home", systemImage: "house.fill") }

            EmployeeCheckInView(
                authService: container.authService,
                storeRepository: container.storeRepository,
                checkInService: container.checkInService,
                checkInRepository: container.checkInRepository,
                locationService: container.locationService
            )
            .tabItem { Label("Check In", systemImage: "location.fill") }

            EmployeeHistoryView(
                authService: container.authService,
                checkInRepository: container.checkInRepository,
                csvExporter: container.csvExporter
            )
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            EmployeeSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
