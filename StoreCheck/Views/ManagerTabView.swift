import SwiftUI

struct ManagerTabView: View {
    var body: some View {
        TabView {
            ManagerDashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar") }
            ManageStoresView()
                .tabItem { Label("Stores", systemImage: "map") }
            ManageEmployeesView()
                .tabItem { Label("Employees", systemImage: "person.3") }
        }
    }
}
