import FirebaseAuth
import FirebaseCore
import SwiftUI

struct EmployeeSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @StateObject private var vm = SettingsViewModel()
    @State private var deleteText = ""
    @State private var showDeleteDialog = false

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    LabeledContent("Name", value: authViewModel.currentUser?.name ?? "StorePass User")
                    LabeledContent("Email", value: authViewModel.currentUser?.email ?? "No email")
                    LabeledContent("Role", value: authViewModel.currentUser?.role.rawValue.capitalized ?? "Unknown")
                }

                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        Task { await authViewModel.signOut() }
                    }

                    Button("Delete Account", role: .destructive) {
                        showDeleteDialog = true
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Settings")
            .alert("Delete account", isPresented: $showDeleteDialog) {
                TextField("Type DELETE", text: $deleteText)
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    guard deleteText == "DELETE" else {
                        vm.errorMessage = "Please type DELETE to confirm."
                        return
                    }
                    Task {
                        let mode: String
                        if authViewModel.currentUser?.role == .manager {
                            mode = "manager_delete_all"
                        } else {
                            mode = "employee"
                        }
                        await vm.deleteAccount(mode: mode)
                        if vm.errorMessage == nil {
                            await authViewModel.signOut()
                        }
                    }
                }
            } message: {
                Text("This action is permanent.")
            }
            .alert("Settings", isPresented: Binding(get: { vm.errorMessage != nil }, set: { _ in vm.errorMessage = nil })) {
                Button("OK", role: .cancel) { vm.errorMessage = nil }
            } message: { Text(vm.errorMessage ?? "") }
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var errorMessage: String?

    func deleteAccount(mode: String) async {
        do {
            _ = try await callable(name: "deleteMyAccount", payload: ["mode": mode])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func callable(name: String, payload: [String: Any]) async throws -> [String: Any] {
        guard let user = Auth.auth().currentUser else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }

        guard let projectID = FirebaseApp.app()?.options.projectID else {
            throw NSError(domain: "StorePass", code: 4002, userInfo: [NSLocalizedDescriptionKey: "Firebase project is not configured correctly."])
        }

        let token = try await user.getIDToken()
        guard let url = URL(string: "https://us-central1-\(projectID).cloudfunctions.net/\(name)") else {
            throw NSError(domain: "StorePass", code: 4003, userInfo: [NSLocalizedDescriptionKey: "Unable to build backend URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": payload])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "StorePass", code: 4004, userInfo: [NSLocalizedDescriptionKey: "Unexpected backend response."])
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let errorObj = object["error"] as? [String: Any] {
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorObj["message"] as? String ?? "Backend error"])
        }
        return object["result"] as? [String: Any] ?? object
    }
}
