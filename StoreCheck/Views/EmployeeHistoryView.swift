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

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

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
            .navigationTitle("Check-in History")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.copyAllVisible()
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
            if viewModel.hasMultipleStores {
                TimesheetLabeledMenu(title: "Store", selectionTitle: viewModel.selectedStoreName) {
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
            } else {
                TimesheetLabeledMenu(
                    title: "Store",
                    selectionTitle: viewModel.selectedStoreName,
                    isInteractive: false
                ) {
                    EmptyView()
                }
            }

            HStack {
                Text("Selected day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: $viewModel.selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DS.Colors.background.opacity(0.8), in: Capsule())
            }

            HStack {
                Text(viewModel.selectedDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Daily total: \(viewModel.formattedDuration(seconds: viewModel.dailyTotalSeconds))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.red)
                .listRowBackground(DS.Colors.card)
        } else if viewModel.visibleCheckIns.isEmpty {
            Text("No check-ins yet. Make a check-in to see history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .listRowBackground(DS.Colors.card)
        } else {
            TimesheetListCard {
                TimesheetColumnHeaderRow(leadingTitle: "Store")
            } rows: {
                ForEach(Array(viewModel.visibleCheckIns.enumerated()), id: \.element.id) { index, item in
                    timesheetRow(for: item, showDivider: index < viewModel.visibleCheckIns.count - 1)
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
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
        }
    }

    private func timesheetRow(for item: CheckIn, showDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.storeName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Text(timeFormatter.string(from: item.checkInTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 95, alignment: .leading)
                Text(item.checkOutTime.map { timeFormatter.string(from: $0) } ?? "Open")
                    .font(.caption.monospacedDigit())
                    .frame(width: 95, alignment: .leading)
                Text(viewModel.formattedDuration(seconds: item.computedDurationSeconds ?? 0))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
            }

            Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if showDivider {
                Divider()
                    .opacity(0.2)
            }
        }
        .padding(.vertical, 8)
    }
}
