import SwiftUI

struct ManageEmployeesView: View {
    @StateObject private var vm: EmployeeManagementViewModel
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var assignedStores = ""
    @State private var storeEditor: [String: String] = [:]

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        _vm = StateObject(wrappedValue: EmployeeManagementViewModel(employeeRepository: employeeRepository, authRepository: authRepository))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    createEmployeeCard
                    filterCard
                    employeesCard
                }
                .padding(DS.Spacing.m)
            }
            .background(DS.Colors.background.ignoresSafeArea())
            .navigationTitle("Employees")
            .task { await vm.load() }
            .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { _ in vm.errorMessage = nil })) {
                Button("OK", role: .cancel) { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
        }
    }

    private var createEmployeeCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Create Employee")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            SecureField("Temporary password", text: $password)
                .textFieldStyle(.roundedBorder)
            TextField("Assigned store IDs (comma separated)", text: $assignedStores)
                .textFieldStyle(.roundedBorder)

            Button("Create") {
                Task {
                    let ids = assignedStores
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    await vm.createEmployee(name: name, email: email, password: password, assignedStores: ids)
                    name = ""
                    email = ""
                    password = ""
                    assignedStores = ""
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .cardStyle()
    }

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Filter")
                .font(.headline)
            TextField("Optional store id", text: $vm.filterStoreId)
                .textFieldStyle(.roundedBorder)
        }
        .cardStyle()
    }

    private var employeesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Linked Employees")
                .font(.headline)

            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if vm.filteredEmployees.isEmpty {
                Text("No linked employees found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.filteredEmployees) { employee in
                    employeeRow(employee)
                    if employee.id != vm.filteredEmployees.last?.id {
                        Divider().overlay(.white.opacity(0.12))
                    }
                }
            }
        }
        .cardStyle()
    }

    private func employeeRow(_ employee: EmployeeSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(employee.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(employee.email ?? "-")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { employee.isActive },
                    set: { isOn in
                        Task { await vm.setActive(employeeId: employee.employeeUserId, isActive: isOn) }
                    }
                ))
                .labelsHidden()
            }

            Text("Assigned Stores: \((employee.assignedStoreIds.isEmpty ? ["None"] : employee.assignedStoreIds).joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Edit stores (comma separated)", text: Binding(
                get: {
                    storeEditor[employee.id] ?? employee.assignedStoreIds.joined(separator: ", ")
                },
                set: { storeEditor[employee.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save Stores") {
                    Task {
                        let raw = storeEditor[employee.id] ?? employee.assignedStoreIds.joined(separator: ",")
                        let ids = raw
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        await vm.updateStores(employeeId: employee.employeeUserId, storeIds: ids)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Remove Link", role: .destructive) {
                    Task { await vm.unlink(employeeId: employee.employeeUserId) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
