import SwiftUI

struct EmployeeTabView: View {
    var body: some View {
        TabView {
            EmployeeDashboardView()
                .tabItem { Label("Home", systemImage: "house") }
            EmployeeHistoryView()
                .tabItem { Label("History", systemImage: "clock") }
        }
    }
}
