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
                Section {
                    HStack {
                        Text("Selected day")
                            .foregroundStyle(.secondary)
                        Spacer()
                        DatePicker("", selection: $viewModel.selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.08), in: Capsule())
                    }

                    HStack {
                        Text(viewModel.selectedDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.headline)
                        Spacer()
                        Text("Daily total \(viewModel.formattedDuration(seconds: viewModel.dailyTotalSeconds))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                .listRowBackground(DS.Colors.card)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                if viewModel.visibleCheckIns.isEmpty, viewModel.errorMessage == nil {
                    Text("No check-ins yet. Make a check-in to see history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        rowHeader
                        ForEach(viewModel.visibleCheckIns) { item in
                            timesheetRow(for: item)
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
                    } header: {
                        Text("Timesheet")
                            .textCase(nil)
                    }
                    .listRowBackground(DS.Colors.card)
                }
            }
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

    private var rowHeader: some View {
        HStack(spacing: 8) {
            Text("Store")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Start")
                .frame(width: 100, alignment: .leading)
            Text("End")
                .frame(width: 100, alignment: .leading)
            Text("Time")
                .frame(width: 76, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    private func timesheetRow(for item: CheckIn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.storeName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(timeFormatter.string(from: item.checkInTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 100, alignment: .leading)
                Text(item.checkOutTime.map { timeFormatter.string(from: $0) } ?? "Open")
                    .font(.caption.monospacedDigit())
                    .frame(width: 100, alignment: .leading)
                Text(viewModel.formattedDuration(seconds: item.computedDurationSeconds ?? 0))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.blue)
                    .frame(width: 76, alignment: .trailing)
            }

            Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.2)
        }
    }
}
