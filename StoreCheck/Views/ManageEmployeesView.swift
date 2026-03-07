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
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        ScreenHeader(
                            title: "Employees",
                            subtitle: "View members, memberships, and account status",
                            icon: "person.3"
                        )

                        summaryAndFilterCard

                        if viewModel.filteredEmployees.isEmpty {
                            EmptyStateView(
                                icon: "person.crop.circle.badge.questionmark",
                                title: "No employees found",
                                message: "Employees appear after joining with a valid store code."
                            )
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(viewModel.filteredEmployees) { employee in
                                    NavigationLink {
                                        EmployeeDetailView(employee: employee, viewModel: viewModel)
                                    } label: {
                                        employeeRow(employee)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if let successMessage = viewModel.successMessage {
                            BannerView(text: successMessage, isError: false)
                        }

                        if let error = viewModel.employeeError {
                            BannerView(text: error, isError: true)
                        }
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
            }
            .navigationTitle("Employees")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                Task { await viewModel.load() }
            }
            .alert("Employee Action", isPresented: Binding(get: { viewModel.pendingRemoval != nil }, set: { if !$0 { viewModel.cancelPendingRemoval() } })) {
                Button("Remove", role: .destructive) {
                    Task { await viewModel.executePendingRemoval() }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelPendingRemoval()
                }
            } message: {
                Text(viewModel.removalConfirmationMessage)
            }
        }
    }

    private var summaryAndFilterCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    MetricChip(label: "Employees", value: "\(viewModel.filteredEmployees.count)", icon: "person.2")
                    MetricChip(label: "Stores", value: "\(viewModel.stores.count)", icon: "building.2")
                }

                Picker("Store", selection: $viewModel.selectedStoreId) {
                    Text("All Stores").tag(EmployeeManagementViewModel.allStoresFilter)
                    ForEach(viewModel.stores) { store in
                        Text(store.name).tag(store.id)
                    }
                }
                .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func employeeRow(_ employee: EmployeeSummary) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(employee.name)
                            .font(DS.Typography.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(employee.email ?? "No email available")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }

                    Spacer(minLength: 0)

                    StatBadge(
                        style: employee.userIsActive ? .approved : .rejected,
                        text: employee.userIsActive ? "Active" : "Inactive"
                    )
                }

                Divider()

                Text(viewModel.storeSummary(for: employee))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmployeeDetailView: View {
    let employee: EmployeeSummary
    @ObservedObject var viewModel: EmployeeManagementViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                profileCard
                membershipsCard
                actionsCard
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.m)
        }
        .background(AppBackground())
        .navigationTitle("Employee")
    }

    private var profileCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: employee.name, subtitle: employee.email ?? "No email", icon: "person.crop.circle")
                KeyValueRow(title: "Status", value: employee.userIsActive ? "Active" : "Inactive")
                KeyValueRow(title: "Memberships", value: "\(employee.storeNames.count)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var membershipsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Store Memberships", subtitle: "Current active assignments", icon: "building.2")

                if employee.storeNames.isEmpty {
                    Text("No active memberships")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    ForEach(employee.storeNames, id: \.self) { storeName in
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Colors.success)
                            Text(storeName)
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.textPrimary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Actions", subtitle: "Membership and account controls", icon: "slider.horizontal.3")

                Button(employee.userIsActive ? "Deactivate Account" : "Activate Account") {
                    Task { await viewModel.setActive(employeeId: employee.id, isActive: !employee.userIsActive) }
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Remove From Selected Store", role: .destructive) {
                    viewModel.prepareRemoval(for: employee)
                }
                .buttonStyle(DestructiveButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
