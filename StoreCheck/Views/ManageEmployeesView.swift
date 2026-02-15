import SwiftUI

struct EmployeeManagementView: View {
    @StateObject private var viewModel: EmployeeManagementViewModel

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        _viewModel = StateObject(
            wrappedValue: EmployeeManagementViewModel(
                employeeRepository: employeeRepository,
                authRepository: authRepository
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                filterSection
                employeesSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Employees")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .alert("Employees", isPresented: Binding(get: { viewModel.employeeError != nil }, set: { _ in viewModel.employeeError = nil })) {
                Button("OK", role: .cancel) { viewModel.employeeError = nil }
            } message: {
                Text(viewModel.employeeError ?? "")
            }
        }
    }

    private var filterSection: some View {
        Section("Store Filter") {
            Picker("Store", selection: $viewModel.selectedStoreId) {
                Text("All").tag(EmployeeManagementViewModel.allStoresFilter)
                ForEach(viewModel.stores) { store in
                    Text(store.name).tag(store.id)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.selectedStoreId != EmployeeManagementViewModel.allStoresFilter,
               let activeStore = viewModel.stores.first(where: { $0.id == viewModel.selectedStoreId }) {
                Text("Showing employees in \(activeStore.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(DS.Colors.card)
    }

    private var employeesSection: some View {
        Section("Team") {
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if viewModel.filteredEmployees.isEmpty {
                Text("No employees have joined yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.filteredEmployees) { employee in
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text(employee.name)
                            .font(.headline)
                        Text(employee.email ?? "No email on file")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(viewModel.storeSummary(for: employee))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Label(
                            employee.userIsActive ? "Active" : "Inactive",
                            systemImage: employee.userIsActive ? "checkmark.circle.fill" : "minus.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(employee.userIsActive ? .green : .orange)

                        HStack {
                            Menu("Remove from store") {
                                ForEach(viewModel.stores.filter { employee.storeIds.contains($0.id) }) { store in
                                    Button(store.name, role: .destructive) {
                                        Task { await viewModel.removeFromStore(employeeId: employee.id, storeId: store.id) }
                                    }
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Remove all", role: .destructive) {
                                Task { await viewModel.removeFromAll(employeeId: employee.id) }
                            }
                            .buttonStyle(.bordered)

                            Button(employee.userIsActive ? "Disable" : "Enable") {
                                Task { await viewModel.setActive(employeeId: employee.id, isActive: !employee.userIsActive) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listRowBackground(DS.Colors.card)
    }
}

struct ManageEmployeesView: View {
    let employeeRepository: EmployeeManagementRepositoryProtocol
    let authRepository: AuthRepositoryProtocol

    var body: some View {
        EmployeeManagementView(employeeRepository: employeeRepository, authRepository: authRepository)
    }
}
