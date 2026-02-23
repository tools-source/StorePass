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
            .safeAreaInset(edge: .top) {
                if let bannerMessage = viewModel.bannerMessage {
                    HStack(spacing: DS.Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                        Text(bannerMessage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Dismiss") {
                            viewModel.bannerMessage = nil
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.s)
                    .background(.red.opacity(0.92))
                }
            }
            .alert("Employees", isPresented: Binding(get: { viewModel.employeeError != nil }, set: { _ in viewModel.employeeError = nil })) {
                Button("OK", role: .cancel) { viewModel.employeeError = nil }
            } message: {
                Text(viewModel.employeeError ?? "")
            }
            .alert("Employees", isPresented: Binding(get: { viewModel.successMessage != nil }, set: { _ in viewModel.successMessage = nil })) {
                Button("OK", role: .cancel) { viewModel.successMessage = nil }
            } message: {
                Text(viewModel.successMessage ?? "")
            }
            .alert(
                "Remove from store",
                isPresented: Binding(get: { viewModel.pendingRemoval != nil }, set: { if !$0 { viewModel.cancelPendingRemoval() } })
            ) {
                Button("Remove", role: .destructive) {
                    Task { await viewModel.executePendingRemoval() }
                }
                Button("Cancel", role: .cancel) { viewModel.cancelPendingRemoval() }
            } message: {
                Text(viewModel.removalConfirmationMessage)
            }
            .confirmationDialog(
                "Remove from which store?",
                isPresented: Binding(get: { viewModel.pendingStoreSelection != nil }, set: { if !$0 { viewModel.cancelPendingStoreSelection() } }),
                presenting: viewModel.pendingStoreSelection
            ) { selection in
                ForEach(selection.targets) { target in
                    Button("\(target.storeName) (\(target.storeId))", role: .destructive) {
                        viewModel.confirmRemovalFromSelection(target: target)
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelPendingStoreSelection()
                }
            } message: { selection in
                Text("Choose the store membership to remove for \(selection.employeeName).")
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
                        storeSummary: viewModel.storeSummary(for: employee)
                    )
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", role: .destructive) {
                            viewModel.prepareRemoval(for: employee)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
        }
        .listRowBackground(DS.Colors.card)
    }
}

private struct EmployeeCardView: View {
    let employee: EmployeeSummary
    let storeSummary: String

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

            if employee.storeIds.isEmpty {
                Text("No stores assigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Spacing.s)
    }
}

struct ManageEmployeesView: View {
    let employeeRepository: EmployeeManagementRepositoryProtocol
    let authRepository: AuthRepositoryProtocol

    var body: some View {
        EmployeeManagementView(employeeRepository: employeeRepository, authRepository: authRepository)
    }
}
