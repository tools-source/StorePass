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
                Section { contentSection }
            }
            .safeAreaInset(edge: .top) { filterBar }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-ins")
            .toolbar { toolbarContent }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in Task { await viewModel.load() } }
            .alert("Clear store check-ins?", isPresented: $showClearAllConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) { Task { await viewModel.clearAllForSelectedStore() } }
            } message: {
                Text("This will delete all check-ins for \(viewModel.selectedStoreName). Continue?")
            }
            .sheet(isPresented: $showFilterSheet) { filterSheet }
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { viewModel.copyVisibleList() } label: { Image(systemName: "doc.on.doc") }
            if let exportURL = viewModel.exportURL() {
                ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
            }
            Button("Clear All", role: .destructive) { showClearAllConfirm = true }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Text(viewModel.selectedStoreName)
                .lineLimit(1)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.Colors.card, in: Capsule())
            Text("\(viewModel.selectedEmployeeName) • \(dateRangeText)")
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { seedDraftFilters(); showFilterSheet = true } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(DS.Colors.background)
    }

    private var contentSection: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading check-ins…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            } else if viewModel.daySections.isEmpty {
                Text("No check-ins for the selected filters.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.daySections) { section in
                    Section {
                        tableHeader
                        ForEach(section.items) { checkInRow($0) }
                    } header: {
                        Text("\(viewModel.formattedDay(section.day)) • Total: \(viewModel.formattedDuration(seconds: section.dailyTotalSeconds))")
                            .textCase(nil)
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Employee").lineLimit(1).minimumScaleFactor(0.9).frame(maxWidth: .infinity, alignment: .leading)
            Text("Start").frame(width: 70, alignment: .leading)
            Text("End").frame(width: 70, alignment: .leading)
            Text("Time").frame(width: 70, alignment: .trailing)
            Text("Verify").frame(width: 76, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func checkInRow(_ item: CheckIn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.employeeName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(viewModel.formattedTime(item.checkInTime)).font(.system(.caption, design: .monospaced)).frame(width: 70, alignment: .leading)
                Text(item.checkOutTime.map(viewModel.formattedTime) ?? "—").font(.system(.caption, design: .monospaced)).frame(width: 70, alignment: .leading)
                Text(viewModel.formattedDuration(item)).font(.system(.caption, design: .monospaced).weight(.semibold)).frame(width: 70, alignment: .trailing)
                verificationBadge(for: item)
            }
            verificationDetails(for: item)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func verificationBadge(for item: CheckIn) -> some View {
        let approved = item.verifyInInside == true
        return Text(approved ? "Inside ✓" : "Outside ✕")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(approved ? .green : .red)
            .frame(width: 76, alignment: .trailing)
    }

    private func verificationDetails(for item: CheckIn) -> some View {
        let distance2 = Int(item.verifyInDistance2Meters ?? 0)
        let accuracy2 = Int(item.verifyInAccuracy2Meters ?? 0)
        let drift = Int(item.verifyInDriftMeters ?? 0)
        let read1 = item.verifyInRead1At.map(viewModel.formattedTime) ?? "—"
        let read2 = item.verifyInRead2At.map(viewModel.formattedTime) ?? "—"
        return Text("d2 \(distance2)m • ±\(accuracy2)m • drift \(drift)m • r1 \(read1) • r2 \(read2)")
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Picker("Store", selection: Binding(get: { draftStoreId ?? "" }, set: { draftStoreId = $0.isEmpty ? nil : $0 })) {
                    ForEach(viewModel.stores) { store in Text(store.name).tag(store.id) }
                }
                Picker("Employee", selection: $draftEmployeeId) {
                    ForEach(viewModel.employeeOptions) { option in Text(option.label).tag(option.id) }
                }
                DatePicker("From", selection: $draftFromDate, displayedComponents: .date)
                DatePicker("To", selection: $draftToDate, displayedComponents: .date)
                Toggle("Open sessions only", isOn: $draftOpenOnly)

                Section("Quick presets") {
                    ForEach(ManagerCheckInsViewModel.DatePreset.allCases) { preset in
                        Button(preset.rawValue) { applyDraftPreset(preset) }
                    }
                }
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        viewModel.clearFilters()
                        seedDraftFilters()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        viewModel.selectedStoreId = draftStoreId
                        viewModel.selectedEmployeeId = draftEmployeeId
                        viewModel.fromDate = Calendar.current.startOfDay(for: draftFromDate)
                        let toStart = Calendar.current.startOfDay(for: draftToDate)
                        viewModel.toDate = Calendar.current.date(byAdding: .day, value: 1, to: toStart) ?? toStart
                        viewModel.showOpenSessionsOnly = draftOpenOnly
                        showFilterSheet = false
                        Task { await viewModel.load() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var dateRangeText: String {
        "\(viewModel.formattedDay(viewModel.fromDate)) → \(viewModel.formattedDay(viewModel.toDate.addingTimeInterval(-1)))"
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
