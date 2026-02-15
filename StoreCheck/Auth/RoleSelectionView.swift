import SwiftUI

struct RoleSelectionView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.m) {
                Text("StoreCheck")
                    .font(.largeTitle.bold())
                NavigationLink("Employee Login") { LoginView(role: .employee) }
                    .buttonStyle(.borderedProminent)
                NavigationLink("Manager Login") { LoginView(role: .manager) }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}
