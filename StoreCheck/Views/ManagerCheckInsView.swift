import SwiftUI

struct ManagerCheckInsView: View {
    @StateObject private var viewModel: ManagerCheckInsViewModel
    @State private var showClearAllConfirm = false
    @State private var editingCheckIn: CheckIn?
    @State private var editStatus: CheckInStatus = .approved
    @State private var editReason = ""
    @State private var editingTimesCheckIn: CheckIn?
    @State private var editCheckInTime = Date()
    @State private var editCheckOutTime = Date()
    @State private var editHasNoCheckout = false
    @State private var editTimesValidationError: String?
    @State private var selectedPhotoCheckIn: CheckIn?
    @State private var selectedFullPhotoURL: URL?

    init(
        storeRepository: StoreRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        authRepository: AuthRepositoryProtocol,
        csvExporter: CSVExportServiceProtocol
    ) {
        _viewModel = StateObject(wrappedValue: ManagerCheckInsViewModel(
            storeRepository: storeRepository,
            checkInRepository: checkInRepository,
            authRepository: authRepository,
            csvExporter: csvExporter
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                filterCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                contentSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-ins")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.copyVisibleList()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }

                    if let exportURL = viewModel.exportURL() {
                        ShareLink(item: exportURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

                    Button("Clear All", role: .destructive) {
                        showClearAllConfirm = true
                    }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in
                Task { await viewModel.load() }
            }
            .alert("Clear store check-ins?", isPresented: $showClearAllConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    Task { await viewModel.clearAllForSelectedStore() }
                }
            } message: {
                let name = viewModel.stores.first(where: { $0.id == viewModel.selectedStoreId })?.name ?? "this store"
                Text("This will delete all check-ins for \(name). Continue?")
            }
            .sheet(item: $editingCheckIn) { checkIn in
                NavigationStack {
                    Form {
                        Picker("Status", selection: $editStatus) {
                            ForEach(CheckInStatus.allCases, id: \.self) { status in
                                Text(status.rawValue.capitalized).tag(status)
                            }
                        }
                        TextField("Reason", text: $editReason)
                    }
                    .navigationTitle("Edit Check-in")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editingCheckIn = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                Task {
                                    await viewModel.update(checkIn, status: editStatus, reason: editReason.isEmpty ? nil : editReason)
                                    editingCheckIn = nil
                                }
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingTimesCheckIn) { checkIn in
                NavigationStack {
                    Form {
                        DatePicker("Check-in Time", selection: $editCheckInTime, displayedComponents: [.date, .hourAndMinute])

                        Toggle("No checkout yet", isOn: $editHasNoCheckout)
                            .tint(DS.Colors.primary)

                        if !editHasNoCheckout {
                            DatePicker("Check-out Time", selection: $editCheckOutTime, displayedComponents: [.date, .hourAndMinute])
                        }

                        if let editTimesValidationError {
                            Text(editTimesValidationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .navigationTitle("Edit Times")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editingTimesCheckIn = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let validationMessage = validateEditTimes(
                                    checkInTime: editCheckInTime,
                                    checkOutTime: editHasNoCheckout ? nil : editCheckOutTime
                                )
                                editTimesValidationError = validationMessage
                                guard validationMessage == nil else { return }

                                Task {
                                    let saveSucceeded = await viewModel.updateTimes(
                                        for: checkIn,
                                        checkInTime: editCheckInTime,
                                        checkOutTime: editHasNoCheckout ? nil : editCheckOutTime
                                    )
                                    if saveSucceeded {
                                        editingTimesCheckIn = nil
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: editCheckInTime) { _, newValue in
                        editTimesValidationError = validateEditTimes(
                            checkInTime: newValue,
                            checkOutTime: editHasNoCheckout ? nil : editCheckOutTime
                        )
                    }
                    .onChange(of: editCheckOutTime) { _, newValue in
                        editTimesValidationError = validateEditTimes(
                            checkInTime: editCheckInTime,
                            checkOutTime: editHasNoCheckout ? nil : newValue
                        )
                    }
                    .onChange(of: editHasNoCheckout) { _, newValue in
                        editTimesValidationError = validateEditTimes(
                            checkInTime: editCheckInTime,
                            checkOutTime: newValue ? nil : editCheckOutTime
                        )
                    }
                }
            }
            .sheet(item: $selectedPhotoCheckIn) { checkIn in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Spacing.m) {
                            Text(checkIn.employeeName)
                                .font(.headline)
                            Text(checkIn.storeName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("In: \(viewModel.formattedTime(checkIn.checkInTime)) • Out: \(checkIn.checkOutTime.map(viewModel.formattedTime) ?? "—")")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            photoCard(title: "Check In Photo", urlString: checkIn.checkInPhotoURL)
                            photoCard(title: "Check Out Photo", urlString: checkIn.checkOutPhotoURL)
                        }
                        .padding(DS.Spacing.l)
                    }
                    .background(DS.Colors.background)
                    .navigationTitle("Photos")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { selectedPhotoCheckIn = nil }
                        }
                    }
                }
            }

            .sheet(isPresented: Binding(get: { selectedFullPhotoURL != nil }, set: { if !$0 { selectedFullPhotoURL = nil } })) {
                if let selectedFullPhotoURL {
                    PhotoViewer(title: "Photo", url: selectedFullPhotoURL) {
                        self.selectedFullPhotoURL = nil
                    }
                }
            }
        }
    }

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledMenu(title: "Store", selectionTitle: viewModel.selectedStoreName) {
                if viewModel.stores.isEmpty {
                    Button("No stores available") { }
                        .disabled(true)
                } else {
                    ForEach(viewModel.stores) { store in
                        Button {
                            viewModel.selectedStoreId = store.id
                        } label: {
                            if viewModel.selectedStoreId == store.id {
                                Label(store.name, systemImage: "checkmark")
                            } else {
                                Text(store.name)
                            }
                        }
                    }
                }
            }

            LabeledMenu(title: "Employee", selectionTitle: viewModel.selectedEmployeeName) {
                ForEach(viewModel.employeeOptions) { employee in
                    Button {
                        viewModel.selectedEmployeeId = employee.id
                    } label: {
                        if viewModel.selectedEmployeeId == employee.id {
                            Label(employee.label, systemImage: "checkmark")
                        } else {
                            Text(employee.label)
                        }
                    }
                }
            }

            Toggle("Open sessions only", isOn: $viewModel.showOpenSessionsOnly)
                .tint(DS.Colors.primary)
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(DS.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isLoading {
            ProgressView().frame(maxWidth: .infinity)
                .listRowBackground(DS.Colors.card)
        } else if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .listRowBackground(DS.Colors.card)
        } else if viewModel.daySections.isEmpty {
            Text("No check-ins yet for this store.")
                .foregroundStyle(.secondary)
                .listRowBackground(DS.Colors.card)
        } else {
            ForEach(viewModel.daySections) { section in
                Section {
                    tableHeader
                    ForEach(section.items) { item in
                        checkInRow(item)
                    }
                } header: {
                    HStack {
                        Text(viewModel.formattedDay(section.day))
                        Spacer()
                        Text("Daily total: \(viewModel.formattedDuration(seconds: section.dailyTotalSeconds))")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .textCase(nil)
                }
                .listRowBackground(DS.Colors.card)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Employee")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Start")
                .frame(width: 95, alignment: .leading)
            Text("End")
                .frame(width: 95, alignment: .leading)
            Text("Time")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func checkInRow(_ item: CheckIn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.employeeName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(viewModel.formattedTime(item.checkInTime))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 95, alignment: .leading)
                Text(item.checkOutTime.map(viewModel.formattedTime) ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 95, alignment: .leading)
                Text(viewModel.formattedDuration(item))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .frame(width: 72, alignment: .trailing)
                photoIndicator(for: item)
            }
            .font(.subheadline)

            Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button("Edit") {
                editingCheckIn = item
                editStatus = item.status
                editReason = item.rejectReason ?? ""
            }
            .tint(.blue)

            Button("Edit Times") {
                editingTimesCheckIn = item
                editCheckInTime = item.checkInTime
                if let checkOutTime = item.checkOutTime {
                    editCheckOutTime = checkOutTime
                    editHasNoCheckout = false
                } else {
                    editCheckOutTime = item.checkInTime
                    editHasNoCheckout = true
                }
                editTimesValidationError = validateEditTimes(
                    checkInTime: editCheckInTime,
                    checkOutTime: editHasNoCheckout ? nil : editCheckOutTime
                )
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            if item.hasCheckInPhoto || item.hasCheckOutPhoto {
                Button("Photos") {
                    selectedPhotoCheckIn = item
                }
                .tint(.indigo)
            }
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(item) }
            }
        }
    }

    @ViewBuilder
    private func photoIndicator(for item: CheckIn) -> some View {
        if let urlString = item.checkInPhotoURL, let url = URL(string: urlString) {
            Button {
                selectedFullPhotoURL = url
            } label: {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } placeholder: {
                    Text("Photo")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.Colors.background, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        } else if item.hasCheckInPhoto {
            Text("Photo")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DS.Colors.background, in: Capsule())
        }
    }

    private func photoCard(title: String, urlString: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.textPrimary)

            if let urlString, let url = URL(string: urlString) {
                Button {
                    selectedFullPhotoURL = url
                } label: {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            .clipped()
                    } placeholder: {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Text("No photo captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func validateEditTimes(checkInTime: Date, checkOutTime: Date?) -> String? {
        let maxAllowed = Date().addingTimeInterval(5 * 60)
        if checkInTime > maxAllowed {
            return "Check-in time can’t be more than 5 minutes in the future."
        }
        if let checkOutTime {
            if checkOutTime > maxAllowed {
                return "Check-out time can’t be more than 5 minutes in the future."
            }
            if checkInTime > checkOutTime {
                return "Check-in time must be before check-out time."
            }
        }
        return nil
    }

}

private struct LabeledMenu<Content: View>: View {
    let title: String
    let selectionTitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                content
            } label: {
                HStack {
                    Text(selectionTitle)
                        .lineLimit(1)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DS.Colors.background.opacity(0.8))
                .clipShape(Capsule())
            }
            .accessibilityLabel("\(title) filter")
        }
    }
}
