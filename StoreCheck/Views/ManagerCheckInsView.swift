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
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        ScreenHeader(
                            title: "Attendance",
                            subtitle: "Review check-ins, apply filters, and export reports",
                            icon: "checklist"
                        )

                        filterSummaryCard

                        if viewModel.isLoading {
                            loadingCard
                        }

                        if let error = viewModel.errorMessage {
                            BannerView(text: error, isError: true)
                        }

                        if !viewModel.isLoading && viewModel.daySections.isEmpty {
                            EmptyStateView(
                                icon: "calendar.badge.exclamationmark",
                                title: "No attendance found",
                                message: "Adjust your date or employee filter to see check-ins."
                            )
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(viewModel.daySections) { section in
                                    daySectionCard(section)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
            }
            .navigationTitle("Attendance")
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

                    Button {
                        seedDraftFilters()
                        showFilterSheet = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }

                    Button("Clear", role: .destructive) {
                        showClearAllConfirm = true
                    }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in Task { await viewModel.load() } }
            .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                Task { await viewModel.load() }
            }
            .sheet(isPresented: $showFilterSheet) { filterSheet }
            .alert("Clear store check-ins?", isPresented: $showClearAllConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) { Task { await viewModel.clearAllForSelectedStore() } }
            }
        }
    }

    private var filterSummaryCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    MetricChip(label: "Store", value: viewModel.selectedStoreName, icon: "building.2")
                    MetricChip(label: "Employee", value: viewModel.selectedEmployeeName, icon: "person")
                }

                HStack(spacing: DS.Spacing.s) {
                    MetricChip(label: "From", value: viewModel.fromDate.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
                    MetricChip(label: "To", value: viewModel.toDate.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted), icon: "calendar.badge.clock")
                }

                if viewModel.showOpenSessionsOnly {
                    StatBadge(style: .open, text: "Open sessions only")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var loadingCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                SkeletonLine(width: 140)
                SkeletonLine()
                SkeletonLine(width: 220)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func daySectionCard(_ section: ManagerCheckInsViewModel.DaySection) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack {
                    Text(viewModel.formattedDay(section.day))
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Colors.textPrimary)

                    Spacer()

                    Text(viewModel.formattedDuration(seconds: section.dailyTotalSeconds))
                        .font(DS.Typography.mono.weight(.semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                }

                ForEach(section.items) { item in
                    NavigationLink {
                        ManagerCheckInDetailView(item: item)
                    } label: {
                        checkInRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checkInRow(_ item: CheckIn) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.employeeName)
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.Colors.textPrimary)

                Text("\(viewModel.formattedTime(item.checkInTime)) → \(item.checkOutTime.map(viewModel.formattedTime) ?? "Open") • \(viewModel.formattedDuration(item))")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)

                Text("d2 \(Int(item.verifyInDistance2Meters ?? 0))m • ±\(Int(item.verifyInAccuracy2Meters ?? 0))m • drift \(Int(item.verifyInDriftMeters ?? 0))m")
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 6) {
                StatBadge(style: item.verifyInInside == true ? .inside : .outside, text: item.verifyInInside == true ? "Inside" : "Outside")
                StatBadge(style: item.status == .approved ? .approved : .rejected)
            }
        }
        .padding(.vertical, 4)
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
                        ScreenHeader(title: item.employeeName, subtitle: item.storeName, icon: "person.crop.square")
                        KeyValueRow(title: "Check-In", value: item.checkInTime.formatted(date: .abbreviated, time: .shortened))
                        KeyValueRow(title: "Check-Out", value: item.checkOutTime?.formatted(date: .abbreviated, time: .shortened) ?? "Open")
                        KeyValueRow(title: "Status", value: item.status.rawValue.capitalized)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: "Verification", subtitle: "Geo-fence evidence", icon: "location.viewfinder")
                        KeyValueRow(title: "Distance", value: "\(Int(item.verifyInDistance2Meters ?? 0))m")
                        KeyValueRow(title: "Accuracy", value: "±\(Int(item.verifyInAccuracy2Meters ?? 0))m")
                        KeyValueRow(title: "Drift", value: "\(Int(item.verifyInDriftMeters ?? 0))m")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.m)
        }
        .background(AppBackground())
        .navigationTitle("Check-In Detail")
    }
}
