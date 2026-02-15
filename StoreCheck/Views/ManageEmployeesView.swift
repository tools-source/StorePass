import SwiftUI

struct ManageEmployeesView: View {
    @StateObject private var vm = EmployeeManagementViewModel(userRepository: AppContainer.shared.userRepository, authRepository: AppContainer.shared.authRepository)
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var assignedStores = ""

    var body: some View {
        EmployeesView(viewModel: vm, name: $name, email: $email, password: $password, assignedStores: $assignedStores)
    }
}

struct EmployeesView: View {
    @ObservedObject var viewModel: EmployeeManagementViewModel
    @Binding var name: String
    @Binding var email: String
    @Binding var password: String
    @Binding var assignedStores: String

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Employee") {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                    SecureField("Temporary password", text: $password)
                    TextField("Assigned store IDs (comma separated)", text: $assignedStores)
                    Button("Create") {
                        Task {
                            let ids = assignedStores.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            await viewModel.createEmployee(name: name, email: email, password: password, assignedStores: ids)
                        }
                    }
                }

                Section("Employees") {
                    if viewModel.employees.isEmpty {
                        Text("No employees found")
                    } else {
                        ForEach(viewModel.employees) { employee in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(employee.name)
                                    Text(employee.email ?? "-").font(.caption)
                                }
                                Spacer()
                                Toggle("Active", isOn: Binding(get: { employee.isActive }, set: { isOn in
                                    Task { await viewModel.setActive(employee, isActive: isOn) }
                                }))
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Employees")
            .task { await viewModel.load() }
        }
    }
}
