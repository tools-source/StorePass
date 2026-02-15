import UIKit
import SwiftUI

struct EmployeeSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var container: AppContainer

    private var locationPermissionStatus: LocationPermissionStatus {
        LocationPermissionStatus(
            status: container.locationService.authorizationStatus,
            preciseEnabled: container.locationService.isPreciseLocationEnabled
        )
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                storesSection
                permissionsSection
                accountSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Settings")
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            LabeledContent("Name", value: authViewModel.currentUser?.name ?? "StorePass User")
            LabeledContent("Email", value: authViewModel.currentUser?.email ?? "No email available")
            LabeledContent("Provider", value: authViewModel.currentUser?.provider.capitalized ?? "Unknown")
        }
        .listRowBackground(DS.Colors.card)
    }

    private var storesSection: some View {
        Section("Assigned Stores") {
            let stores = authViewModel.currentUser?.assignedStoreIds ?? []
            if stores.isEmpty {
                Text("No stores assigned yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(stores.count) store(s) assigned")
                Text(stores.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(DS.Colors.card)
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Location: \(locationPermissionStatus.title)")
                    .font(.subheadline.weight(.semibold))
                Text(locationPermissionStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open iOS Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .foregroundStyle(DS.Colors.primary)
        }
        .listRowBackground(DS.Colors.card)
    }

    private var accountSection: some View {
        Section("Account") {
            Button(role: .destructive) {
                Task { await authViewModel.signOut() }
            } label: {
                Text("Sign Out")
            }
        }
        .listRowBackground(DS.Colors.card)
    }
}
