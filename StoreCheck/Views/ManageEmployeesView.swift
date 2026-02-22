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
                    EmployeeCardView(
                        employee: employee,
                        stores: viewModel.stores,
                        storeSummary: viewModel.storeSummary(for: employee),
                        onRemoveStore: { storeId in
                            Task { await viewModel.removeFromStore(employeeId: employee.id, storeId: storeId) }
                        },
                        onRemoveAll: {
                            Task { await viewModel.removeFromAll(employeeId: employee.id) }
                        },
                        onToggleActive: {
                            Task { await viewModel.setActive(employeeId: employee.id, isActive: !employee.userIsActive) }
                        }
                    )
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
        }
        .listRowBackground(DS.Colors.card)
    }
}

private struct EmployeeCardView: View {
    let employee: EmployeeSummary
    let stores: [Store]
    let storeSummary: String
    let onRemoveStore: (String) -> Void
    let onRemoveAll: () -> Void
    let onToggleActive: () -> Void

    private var statusText: String { employee.userIsActive ? "Active" : "Disabled" }
    private var statusColor: Color { employee.userIsActive ? .green : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(employee.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Spacer(minLength: DS.Spacing.s)

                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.15), in: Capsule())
            }

            Text(employee.email ?? "Email unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(storeSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: DS.Spacing.s) {
                Menu("Remove from store") {
                    ForEach(stores.filter { employee.storeIds.contains($0.id) }) { store in
                        Button(store.name, role: .destructive) {
                            onRemoveStore(store.id)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Button("Remove all", role: .destructive) {
                    onRemoveAll()
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Spacer()

                Button(employee.userIsActive ? "Disable" : "Enable") {
                    onToggleActive()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }
}

struct ManageEmployeesView: View {
    let employeeRepository: EmployeeManagementRepositoryProtocol
    let authRepository: AuthRepositoryProtocol

    var body: some View {
        EmployeeManagementView(employeeRepository: employeeRepository, authRepository: authRepository)
    }
}
