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
                locationService: container.locationService,
                imageUploadService: container.imageUploadService,
                photoCheckInPipeline: container.photoCheckInPipeline
            )
            .tabItem { Label("Home", systemImage: "house") }

            EmployeeHistoryView(
                authService: container.authService,
                checkInRepository: container.checkInRepository,
                csvExporter: container.csvExporter
            )
            .tabItem { Label("History", systemImage: "clock") }

            EmployeeSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
