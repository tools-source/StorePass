import SwiftUI

struct EmployeeHistoryView: View {
    @StateObject private var vm: EmployeeHistoryViewModel

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        _vm = StateObject(wrappedValue: EmployeeHistoryViewModel(
            authService: authService,
            checkInRepository: checkInRepository,
            csvExporter: csvExporter
        ))
    }

    var body: some View {
        CheckInHistoryView(viewModel: vm)
    }
}

struct CheckInHistoryView: View {
    @ObservedObject var viewModel: EmployeeHistoryViewModel

    @State private var showClearAllConfirm = false
    @State private var editingCheckIn: CheckIn?
    @State private var editStatus: CheckInStatus = .approved
    @State private var editReason = ""
    @State private var filterByDay = false

    private let calendar = Calendar.current

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private let dayHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d") // Sat, Feb 28
        return formatter
    }()

    private struct DaySection: Identifiable {
        let day: Date
        let items: [CheckIn]
        var id: Date { day }
        var dailyTotalSeconds: Int { items.compactMap(\.computedDurationSeconds).reduce(0, +) }
    }

    private var storeFilteredCheckIns: [CheckIn] {
        viewModel.checkIns
            .filter { viewModel.selectedStoreId == nil || $0.storeId == viewModel.selectedStoreId }
            .sorted { $0.checkInTime > $1.checkInTime }
    }

    private var daySections: [DaySection] {
        let source = filterByDay
            ? storeFilteredCheckIns.filter { calendar.isDate($0.checkInTime, inSameDayAs: viewModel.selectedDate) }
            : storeFilteredCheckIns

        let grouped = Dictionary(grouping: source) { calendar.startOfDay(for: $0.checkInTime) }

        return grouped
            .map { day, items in
                DaySection(day: day, items: items.sorted { $0.checkInTime > $1.checkInTime })
            }
            .sorted { $0.day > $1.day }
    }

    private var selectedDayTotalSeconds: Int {
        storeFilteredCheckIns
            .filter { calendar.isDate($0.checkInTime, inSameDayAs: viewModel.selectedDate) }
            .compactMap(\.computedDurationSeconds)
            .reduce(0, +)
    }

    private var visibleItems: [CheckIn] {
        daySections.flatMap(\.items)
    }

    var body: some View {
        NavigationStack {
            List {
                filterCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .listRowBackground(DS.Colors.card)
                } else if daySections.isEmpty {
                    Text("No check-ins yet. Make a check-in to see history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(DS.Colors.card)
                } else {
                    ForEach(daySections) { section in
                        Section {
                            tableHeaderRow
                                .listRowBackground(DS.Colors.card)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
                                .overlay(alignment: .bottom) {
                                    Divider().opacity(0.16)
                                }

                            ForEach(section.items) { item in
                                timesheetRow(for: item)
                                    .listRowBackground(DS.Colors.card)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .overlay(alignment: .bottom) {
                                        Divider().opacity(0.16)
                                    }
                            }
                        } header: {
                            HStack {
                                Text(dayHeaderFormatter.string(from: section.day))
                                Spacer()
                                Text("Daily total: \(viewModel.formattedDuration(seconds: section.dailyTotalSeconds))")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-in History")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.copy(items: visibleItems)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }

                    if let exportURL = viewModel.exportURL(for: visibleItems) {
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
            .alert("Clear history?", isPresented: $showClearAllConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    Task { await viewModel.clearAll() }
                }
            } message: {
                Text("This will delete all your check-ins. Continue?")
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
        }
    }

    // MARK: - Filter Card

    private var filterCard: some View {
        TimesheetHeaderCard {
            TimesheetLabeledMenu(
                title: "Store",
                selectionTitle: viewModel.selectedStoreName,
                isInteractive: viewModel.hasMultipleStores
            ) {
                ForEach(viewModel.storeOptions) { store in
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

            Toggle("Filter by day", isOn: $filterByDay)
                .tint(DS.Colors.primary)
                .font(.subheadline.weight(.semibold))

            if filterByDay {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected day")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DatePicker("Selected day", selection: $viewModel.selectedDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(DS.Colors.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DS.Colors.background.opacity(0.8), in: Capsule())
            }

            Divider().opacity(0.2)

            HStack {
                Text(dayHeaderFormatter.string(from: viewModel.selectedDate))
                    .font(.headline)
                Spacer()
                Text("Daily total: \(viewModel.formattedDuration(seconds: selectedDayTotalSeconds))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.primary)
            }
        }
    }

    // MARK: - Table Header Row (with vertical column lines)
    private var tableHeaderRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Store")
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
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(height: 1)
        }
    }

    private func headerCell(_ text: String, align: Alignment) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: align)
    }

//    private var vLine: some View {
//        Rectangle()
//            .fill(Color.white.opacity(0.12))
//            .frame(width: 1)
//    }


    // MARK: - Row (with vertical column lines)
    private func timesheetRow(for item: CheckIn) -> some View {
        VStack(spacing: 0) {

            HStack(spacing: 8) {
                Text(item.storeName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(timeFormatter.string(from: item.checkInTime))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 95, alignment: .leading)

                Text(item.checkOutTime.map { timeFormatter.string(from: $0) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 95, alignment: .leading)

                Text(viewModel.formattedDuration(seconds: item.computedDurationSeconds ?? 0))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(DS.Colors.primary)
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.subheadline)
            .padding(.vertical, 12)

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            Button("Edit") {
                editingCheckIn = item
                editStatus = item.status
                editReason = item.rejectReason ?? ""
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button("Copy") {
                viewModel.copySingle(item)
            }
            .tint(.indigo)

            if item.checkOutTime == nil {
                Button("Delete", role: .destructive) {
                    Task { await viewModel.delete(item) }
                }
            }
        }
    }

    private func rowCell(_ text: String, align: Alignment) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: align)
    }

    private func rowMonoCell(_ text: String, align: Alignment, isAccent: Bool = false) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(isAccent ? .semibold : .regular))
            .foregroundStyle(isAccent ? DS.Colors.primary : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: align)
    }
}
