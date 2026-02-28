import SwiftUI

struct AppLockOverlay: View {
    @EnvironmentObject private var appLock: AppLockManager

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            DS.Colors.background.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: DS.Spacing.m) {
                Image(systemName: "faceid")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)

                Text("App Locked")
                    .font(.title2.weight(.semibold))

                Text("Use Face ID or your passcode to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    appLock.unlock()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)

                if let lastError = appLock.lastErrorMessage {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: 360)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, DS.Spacing.l)
        }
        .onAppear {
            appLock.unlock()
        }
    }
}
