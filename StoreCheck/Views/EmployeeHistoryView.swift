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
    @State private var filterByDay = true

    private let calendar = Calendar.current
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
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
                            TimesheetListCard {
                                TimesheetColumnHeaderRow(leadingTitle: "Store")
                            } rows: {
                                VStack(spacing: 0) {
                                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                        timesheetRow(for: item)
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

                                        if index < section.items.count - 1 {
                                            Divider().opacity(0.2)
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 6)
                        } header: {
                            HStack {
                                Text(section.day.timesheetDayString())
                                Spacer()
                                Text("Daily total: \(viewModel.formattedDuration(seconds: section.dailyTotalSeconds))")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .textCase(nil)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
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
                DatePicker("Selected day", selection: $viewModel.selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(.subheadline.weight(.semibold))
                    .tint(DS.Colors.primary)
            }

            Divider().opacity(0.2)

            HStack {
                Text(viewModel.selectedDate.timesheetDayString())
                    .font(.headline)
                Spacer()
                Text("Daily total: \(viewModel.formattedDuration(seconds: selectedDayTotalSeconds))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.primary)
            }
        }
    }

    private func timesheetRow(for item: CheckIn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

            Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
