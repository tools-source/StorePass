import SwiftUI

struct ManagerCheckInsView: View {
    @StateObject private var viewModel: ManagerCheckInsViewModel
    @State private var showClearAllConfirm = false
    @State private var editingCheckIn: CheckIn?
    @State private var editStatus: CheckInStatus = .approved
    @State private var editReason = ""

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
                Section("Store") {
                    if viewModel.stores.isEmpty {
                        Text("No stores available.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Store", selection: $viewModel.selectedStoreId) {
                            ForEach(viewModel.stores) { store in
                                Text(store.name).tag(Optional(store.id))
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Open sessions only", isOn: $viewModel.showOpenSessionsOnly)
                }
                .listRowBackground(DS.Colors.card)

                Section("Recent Check-ins") {
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else if viewModel.visibleCheckIns.isEmpty {
                        Text("No check-ins yet for this store.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.visibleCheckIns) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.employeeName)
                                    .font(.headline)
                                Text(item.storeName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("In: \(item.checkInTime.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                Text("Out: \(item.checkOutTime?.formatted(date: .abbreviated, time: .shortened) ?? "Open")")
                                    .font(.caption)
                                Text("Duration: \(viewModel.formattedDuration(item))")
                                    .font(.caption)
                                Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                                    .font(.caption)
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
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    Task { await viewModel.delete(item) }
                                }
                            }
                        }
                    }
                }
                .listRowBackground(DS.Colors.card)
            }
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
        }
    }
}
