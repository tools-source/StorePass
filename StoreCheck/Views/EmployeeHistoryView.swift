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

    var body: some View {
        NavigationStack {
            List {
                DatePicker("Day", selection: $viewModel.selectedDate, displayedComponents: .date)
                    .listRowBackground(DS.Colors.card)

                Text("Daily total: \(viewModel.formattedDuration(seconds: viewModel.dailyTotalSeconds))")
                    .font(.headline)
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
                }

                ForEach(viewModel.visibleCheckIns) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.storeName).font(.headline)
                        Text("In: \(item.checkInTime.formatted(date: .abbreviated, time: .shortened))")
                        Text("Out: \(item.checkOutTime?.formatted(date: .abbreviated, time: .shortened) ?? "Open")")
                        if let seconds = item.computedDurationSeconds {
                            Text("Duration: \(viewModel.formattedDuration(seconds: seconds))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(DS.Colors.card)
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
}
