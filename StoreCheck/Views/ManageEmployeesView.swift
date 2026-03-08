import SwiftUI

struct EmployeeManagementView: View {
    @StateObject private var viewModel: EmployeeManagementViewModel

    init(
        employeeRepository: EmployeeManagementRepositoryProtocol,
        authRepository: AuthRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol
    ) {
        _viewModel = StateObject(
            wrappedValue: EmployeeManagementViewModel(
                employeeRepository: employeeRepository,
                authRepository: authRepository,
                checkInRepository: checkInRepository
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
                                        EmployeeDetailView(employeeId: employee.id, initialEmployee: employee, viewModel: viewModel)
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
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                viewModel.clearWorkSummaryCache()
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
                        Text("Hourly: \(viewModel.hourlyRateText(for: employee))")
                            .font(DS.Typography.micro)
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
    private enum FormField: Hashable {
        case name
        case hourlyRate
    }

    let employeeId: String
    let initialEmployee: EmployeeSummary
    @ObservedObject var viewModel: EmployeeManagementViewModel
    @State private var editedName = ""
    @State private var editedHourlyRate = ""
    @State private var isSavingProfile = false
    @State private var selectedRemovalStoreId = ""
    @FocusState private var focusedField: FormField?

    private var employee: EmployeeSummary {
        viewModel.employee(withId: employeeId) ?? initialEmployee
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                profileCard
                editProfileCard
                membershipsCard
                actionsCard
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppBackground())
        .navigationTitle("Employee")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
        .task {
            seedEditableFields()
            await viewModel.loadWorkSummary(for: employee)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
            Task { await viewModel.loadWorkSummary(for: employee) }
        }
        .onChange(of: employee.name) { _, _ in
            seedEditableFields()
        }
        .onChange(of: employee.storeIds) { _, _ in
            seedRemovalStoreSelectionIfNeeded()
        }
    }

    private var profileCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: employee.name, subtitle: employee.email ?? "No email", icon: "person.crop.circle")
                KeyValueRow(title: "Status", value: employee.userIsActive ? "Active" : "Inactive")
                KeyValueRow(title: "Memberships", value: "\(employee.storeNames.count)")
                KeyValueRow(title: "Hourly Salary", value: viewModel.hourlyRateText(for: employee))
                KeyValueRow(title: "Approved Sessions", value: viewModel.approvedSessionsText(for: employee.id))
                KeyValueRow(title: "Total Hours", value: viewModel.totalHoursText(for: employee.id))
                KeyValueRow(title: "Total Earned", value: viewModel.totalEarningsText(for: employee))

                Text("Calculated from approved completed check-ins across this manager's stores.")
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editProfileCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Edit Employee", subtitle: "Name and pay rate", icon: "pencil.and.list.clipboard")

                TextField("Full name", text: $editedName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        focusedField = .hourlyRate
                    }
                    .padding(.horizontal, DS.Spacing.s)
                    .frame(height: DS.Metrics.rowHeight)
                    .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                KeyValueRow(title: "Employee Email", value: employee.email ?? "No email on file")

                Text("Email can only be changed by the employee account.")
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)

                TextField("Hourly salary (e.g. 18.50)", text: $editedHourlyRate)
                    .keyboardType(.decimalPad)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .hourlyRate)
                    .padding(.horizontal, DS.Spacing.s)
                    .frame(height: DS.Metrics.rowHeight)
                    .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(isSavingProfile ? "Saving..." : "Save Employee") {
                    Task { await saveProfile() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSavingProfile || editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

                if removableStores.isEmpty {
                    Text("No active store memberships to remove.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    Picker("Store", selection: $selectedRemovalStoreId) {
                        ForEach(removableStores) { store in
                            Text(store.name).tag(store.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Button("Remove From Selected Store", role: .destructive) {
                    viewModel.prepareRemoval(for: employee, preferredStoreId: selectedRemovalStoreId)
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(selectedRemovalStoreId.isEmpty || removableStores.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func seedEditableFields() {
        editedName = employee.name
        if let hourlyRateCents = employee.hourlyRateCents {
            let value = Decimal(hourlyRateCents) / 100
            editedHourlyRate = NSDecimalNumber(decimal: value).stringValue
        } else {
            editedHourlyRate = ""
        }
        seedRemovalStoreSelectionIfNeeded()
    }

    private func seedRemovalStoreSelectionIfNeeded() {
        if let selected = removableStores.first(where: { $0.id == selectedRemovalStoreId }) {
            selectedRemovalStoreId = selected.id
            return
        }
        selectedRemovalStoreId = removableStores.first?.id ?? ""
    }

    private struct RemovableStoreOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private var removableStores: [RemovableStoreOption] {
        if employee.storeIds.count == employee.storeNames.count {
            return zip(employee.storeIds, employee.storeNames).map { RemovableStoreOption(id: $0.0, name: $0.1) }
        }
        return employee.storeIds.map { storeId in
            let resolvedName = viewModel.stores.first(where: { $0.id == storeId })?.name ?? storeId
            return RemovableStoreOption(id: storeId, name: resolvedName)
        }
    }

    private func saveProfile() async {
        focusedField = nil
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)

        let hourlyRateCents: Int?
        let hourlyTrimmed = editedHourlyRate.trimmingCharacters(in: .whitespacesAndNewlines)
        if hourlyTrimmed.isEmpty {
            hourlyRateCents = nil
        } else if let value = Decimal(string: hourlyTrimmed), value >= 0 {
            hourlyRateCents = NSDecimalNumber(decimal: value * 100).intValue
        } else {
            viewModel.employeeError = "Enter a valid hourly salary."
            return
        }

        isSavingProfile = true
        await viewModel.updateEmployeeProfile(
            employeeId: employee.id,
            name: trimmedName,
            hourlyRateCents: hourlyRateCents,
            expectedStartMinutesFromMidnight: employee.expectedStartMinutesFromMidnight
        )
        isSavingProfile = false
    }
}

struct ManageEmployeesView: View {
    let employeeRepository: EmployeeManagementRepositoryProtocol
    let authRepository: AuthRepositoryProtocol
    let checkInRepository: CheckInRepositoryProtocol

    var body: some View {
        EmployeeManagementView(
            employeeRepository: employeeRepository,
            authRepository: authRepository,
            checkInRepository: checkInRepository
        )
    }
}
