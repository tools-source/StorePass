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
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    CardView {
                        Picker("Store", selection: $viewModel.selectedStoreId) {
                            Text("All Stores").tag(EmployeeManagementViewModel.allStoresFilter)
                            ForEach(viewModel.stores) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                    }

                    if viewModel.filteredEmployees.isEmpty {
                        EmptyStateView(icon: "person.3", title: "No employees", message: "Employees who join your stores appear here.")
                    } else {
                        ForEach(viewModel.filteredEmployees) { employee in
                            CardView {
                                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                                    HStack {
                                        Text(employee.name).font(.headline)
                                        Spacer()
                                        StatBadge(style: employee.userIsActive ? .approved : .rejected, text: employee.userIsActive ? "Active" : "Inactive")
                                    }
                                    Text(employee.email ?? "No email")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.storeSummary(for: employee))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !employee.storeIds.isEmpty {
                                        Button("Remove from Store", role: .destructive) {
                                            Task {
                                                await viewModel.removeEmployee(employeeId: employee.id, employeeName: employee.name, targetStoreIds: viewModel.targetStoreIds(for: employee))
                                            }
                                        }
                                        .buttonStyle(DestructiveButtonStyle())
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(DS.Spacing.m)
            }
            .background(DS.Colors.background)
            .navigationTitle("Employees")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .alert("Employees", isPresented: Binding(get: { viewModel.employeeError != nil }, set: { _ in viewModel.employeeError = nil })) {
                Button("OK", role: .cancel) { }
            } message: { Text(viewModel.employeeError ?? "") }
            .alert(
                "Remove from store",
                isPresented: Binding(get: { viewModel.pendingRemoval != nil }, set: { if !$0 { viewModel.cancelPendingRemoval() } })
            ) {
                Button("Remove", role: .destructive) { Task { await viewModel.executePendingRemoval() } }
                Button("Cancel", role: .cancel) { viewModel.cancelPendingRemoval() }
            } message: { Text(viewModel.removalConfirmationMessage) }
        }
    }
}

struct ManageEmployeesView: View {
    let employeeRepository: EmployeeManagementRepositoryProtocol
    let authRepository: AuthRepositoryProtocol

    var body: some View {
        EmployeeManagementView(employeeRepository: employeeRepository, authRepository: authRepository)
    }
}
