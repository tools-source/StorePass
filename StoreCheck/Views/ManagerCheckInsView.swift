import SwiftUI

struct ManagerCheckInsView: View {
    @StateObject private var viewModel: ManagerCheckInsViewModel
    @State private var showClearAllConfirm = false
    @State private var showFilterSheet = false

    @State private var draftStoreId: String?
    @State private var draftEmployeeId: String = ManagerCheckInsViewModel.allEmployeesId
    @State private var draftFromDate = Date()
    @State private var draftToDate = Date()
    @State private var draftOpenOnly = false

    init(storeRepository: StoreRepositoryProtocol, checkInRepository: CheckInRepositoryProtocol, authRepository: AuthRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        _viewModel = StateObject(wrappedValue: ManagerCheckInsViewModel(storeRepository: storeRepository, checkInRepository: checkInRepository, authRepository: authRepository, csvExporter: csvExporter))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.visibleCheckIns) { item in
                    NavigationLink {
                        ManagerCheckInDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.employeeName).font(.headline).lineLimit(1)
                                Spacer()
                                StatBadge(style: item.verifyInInside == true ? .inside : .outside, text: item.verifyInInside == true ? "Inside ✓" : "Outside ✕")
                            }
                            Text("\(viewModel.formattedTime(item.checkInTime)) → \(item.checkOutTime.map(viewModel.formattedTime) ?? "Open") • \(viewModel.formattedDuration(item))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(item.status.rawValue.capitalized) • d2 \(Int(item.verifyInDistance2Meters ?? 0))m • ±\(Int(item.verifyInAccuracy2Meters ?? 0))m • drift \(Int(item.verifyInDriftMeters ?? 0))m")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(DS.Colors.card)
                    .listRowSeparator(.hidden)
                }
            }
            .safeAreaInset(edge: .top) { filterBar }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-ins")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { viewModel.copyVisibleList() } label: { Image(systemName: "doc.on.doc") }
                    if let exportURL = viewModel.exportURL() {
                        ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                    }
                    Button("Clear", role: .destructive) { showClearAllConfirm = true }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in Task { await viewModel.load() } }
            .sheet(isPresented: $showFilterSheet) { filterSheet }
            .alert("Clear store check-ins?", isPresented: $showClearAllConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) { Task { await viewModel.clearAllForSelectedStore() } }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text(viewModel.selectedStoreName).font(.caption.weight(.semibold)).lineLimit(1)
            Text(viewModel.selectedEmployeeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { seedDraftFilters(); showFilterSheet = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Colors.background)
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Picker("Store", selection: Binding(get: { draftStoreId ?? "" }, set: { draftStoreId = $0.isEmpty ? nil : $0 })) {
                    ForEach(viewModel.stores) { Text($0.name).tag($0.id) }
                }
                Picker("Employee", selection: $draftEmployeeId) {
                    ForEach(viewModel.employeeOptions) { Text($0.label).tag($0.id) }
                }
                DatePicker("From", selection: $draftFromDate, displayedComponents: .date)
                DatePicker("To", selection: $draftToDate, displayedComponents: .date)
                Toggle("Open sessions only", isOn: $draftOpenOnly)
                Section("Presets") {
                    ForEach([ManagerCheckInsViewModel.DatePreset.today, .yesterday, .last7, .thisMonth], id: \.id) { preset in
                        Button(preset.rawValue) { applyDraftPreset(preset) }
                    }
                }
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { viewModel.clearFilters(); seedDraftFilters() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        viewModel.selectedStoreId = draftStoreId
                        viewModel.selectedEmployeeId = draftEmployeeId
                        viewModel.fromDate = Calendar.current.startOfDay(for: draftFromDate)
                        viewModel.toDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: draftToDate)) ?? draftToDate
                        viewModel.showOpenSessionsOnly = draftOpenOnly
                        showFilterSheet = false
                        Task { await viewModel.load() }
                    }
                }
            }
        }
    }

    private func seedDraftFilters() {
        draftStoreId = viewModel.selectedStoreId
        draftEmployeeId = viewModel.selectedEmployeeId
        draftFromDate = viewModel.fromDate
        draftToDate = viewModel.toDate.addingTimeInterval(-1)
        draftOpenOnly = viewModel.showOpenSessionsOnly
    }

    private func applyDraftPreset(_ preset: ManagerCheckInsViewModel.DatePreset) {
        viewModel.applyPreset(preset)
        draftFromDate = viewModel.fromDate
        draftToDate = viewModel.toDate.addingTimeInterval(-1)
    }
}

private struct ManagerCheckInDetailView: View {
    let item: CheckIn

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text(item.employeeName).font(.headline)
                        Text("\(item.checkInTime.formatted(date: .abbreviated, time: .shortened)) → \(item.checkOutTime?.formatted(date: .omitted, time: .shortened) ?? "Open")")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text("Verification")
                            .font(.headline)
                        Text("d2 \(Int(item.verifyInDistance2Meters ?? 0))m • ±\(Int(item.verifyInAccuracy2Meters ?? 0))m • drift \(Int(item.verifyInDriftMeters ?? 0))m")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(DS.Spacing.m)
        }
        .navigationTitle("Check-in")
    }
}
