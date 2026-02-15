import SwiftUI

struct EmployeeSetupRequiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(DS.Colors.primary)
            Text("Employee Setup Required")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Your /employees profile could not be created automatically. Please try again or contact support.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background.ignoresSafeArea())
    }
}
