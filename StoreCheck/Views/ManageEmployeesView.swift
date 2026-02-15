import SwiftUI

struct ManageEmployeesView: View {
    @StateObject private var vm: EmployeeManagementViewModel
    @State private var editingEmployee: EmployeeSummary?
    @State private var selectedStoreIds: Set<String> = []

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        _vm = StateObject(wrappedValue: EmployeeManagementViewModel(employeeRepository: employeeRepository, authRepository: authRepository))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Filter") {
                    Picker("Store", selection: $vm.selectedStoreId) {
                        Text("All Stores").tag("all")
                        ForEach(vm.stores) { store in
                            Text(store.name).tag(store.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Employees") {
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if vm.filteredEmployees.isEmpty {
                        Text("No employees joined your stores yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.filteredEmployees) { employee in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(employee.name).font(.headline)
                                Text(employee.email ?? "No email")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(employee.storeNames.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(employee.userIsActive ? "Active" : "Inactive")
                                    .font(.caption2)
                                    .foregroundStyle(employee.userIsActive ? .green : .orange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await vm.removeFromAll(employeeId: employee.id) }
                                } label: {
                                    Label("Remove All", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Edit assigned stores") {
                                    editingEmployee = employee
                                    selectedStoreIds = Set(employee.storeIds)
                                }
                                Button(employee.userIsActive ? "Deactivate" : "Reactivate") {
                                    Task { await vm.setActive(employeeId: employee.id, isActive: !employee.userIsActive) }
                                }
                                Menu("Remove from a store") {
                                    ForEach(vm.stores.filter { employee.storeIds.contains($0.id) }) { store in
                                        Button(store.name, role: .destructive) {
                                            Task { await vm.removeFromStore(employeeId: employee.id, storeId: store.id) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Manage Employees")
            .task { await vm.load() }
            .refreshable { await vm.load() }
            .sheet(item: $editingEmployee) { employee in
                NavigationStack {
                    List {
                        ForEach(vm.stores) { store in
                            MultipleSelectionRow(title: store.name, isSelected: selectedStoreIds.contains(store.id)) {
                                if selectedStoreIds.contains(store.id) {
                                    selectedStoreIds.remove(store.id)
                                } else {
                                    selectedStoreIds.insert(store.id)
                                }
                            }
                        }
                    }
                    .navigationTitle("Assign Stores")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editingEmployee = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                Task { await vm.updateStores(employeeId: employee.id, storeIds: Array(selectedStoreIds)) }
                                editingEmployee = nil
                            }
                        }
                    }
                }
            }
            .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { _ in vm.errorMessage = nil })) {
                Button("OK", role: .cancel) { vm.errorMessage = nil }
            } message: { Text(vm.errorMessage ?? "") }
        }
    }
}

private struct MultipleSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
        }
        .foregroundStyle(.white)
    }
}
