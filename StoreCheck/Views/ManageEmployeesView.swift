import SwiftUI

struct ManageEmployeesView: View {
    @StateObject private var vm = EmployeeManagementViewModel(
        userRepository: AppContainer.shared.userRepository,
        authRepository: AppContainer.shared.authRepository
    )
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var assignedStores = ""

    var body: some View {
        NavigationStack {
            VStack {
                Form {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                    SecureField("Temp Password", text: $password)
                    TextField("Assigned Store IDs (comma separated)", text: $assignedStores)
                    Button("Create Employee") {
                        Task {
                            let storeIds = assignedStores.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            await vm.createEmployee(name: name, email: email, password: password, assignedStores: storeIds)
                        }
                    }
                }
                List(vm.employees) { employee in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(employee.name)
                            Text(employee.email).font(.caption)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { employee.isActive }, set: { isOn in
                            Task { await vm.setActive(employee, isActive: isOn) }
                        }))
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("Manage Employees")
            .task { await vm.load() }
        }
    }
}
