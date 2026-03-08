import SwiftUI
import UIKit

struct ManagerCheckInsView: View {
    private enum FilterEditor: String, Identifiable {
        case all
        case store
        case employee
        case fromDate
        case toDate

        var id: String { rawValue }
    }

    @StateObject private var viewModel: ManagerCheckInsViewModel
    private let checkInRepository: CheckInRepositoryProtocol
    @State private var showClearAllConfirm = false
    @State private var activeFilterEditor: FilterEditor?

    @State private var draftStoreId: String?
    @State private var draftEmployeeId: String = ManagerCheckInsViewModel.allEmployeesId
    @State private var draftFromDate = Date()
    @State private var draftToDate = Date()
    @State private var draftOpenOnly = false

    init(storeRepository: StoreRepositoryProtocol, checkInRepository: CheckInRepositoryProtocol, authRepository: AuthRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        self.checkInRepository = checkInRepository
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
                        activeFilterEditor = .all
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .popover(
                        isPresented: editorBinding(.all),
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        filterPopoverContent(.all)
                            .presentationCompactAdaptation(.popover)
                    }

                    Button("Clear", role: .destructive) {
                        showClearAllConfirm = true
                    }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in Task { await viewModel.load() } }
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                Task { await viewModel.load() }
            }
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
                    filterChipButton(
                        label: "Store",
                        value: viewModel.selectedStoreName,
                        icon: "building.2",
                        editor: .store
                    )
                    filterChipButton(
                        label: "Employee",
                        value: viewModel.selectedEmployeeName,
                        icon: "person",
                        editor: .employee
                    )
                }

                HStack(spacing: DS.Spacing.s) {
                    filterChipButton(
                        label: "From",
                        value: viewModel.fromDate.formatted(date: .abbreviated, time: .omitted),
                        icon: "calendar",
                        editor: .fromDate
                    )
                    filterChipButton(
                        label: "To",
                        value: viewModel.toDate.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted),
                        icon: "calendar.badge.clock",
                        editor: .toDate
                    )
                }

                if viewModel.showOpenSessionsOnly {
                    StatBadge(style: .open, text: "Open sessions only")
                }

                Text("Tap any card to edit that filter")
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("attendance_filter_summary_card")
    }

    private func filterChipButton(label: String, value: String, icon: String, editor: FilterEditor) -> some View {
        Button {
            seedDraftFilters()
            activeFilterEditor = editor
        } label: {
            MetricChip(label: label, value: value, icon: icon)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(8)
                }
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: editorBinding(editor),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            filterPopoverContent(editor)
                .presentationCompactAdaptation(.popover)
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
                        ManagerCheckInDetailView(item: item, checkInRepository: checkInRepository, viewModel: viewModel)
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

    private func editorBinding(_ editor: FilterEditor) -> Binding<Bool> {
        Binding(
            get: { activeFilterEditor == editor },
            set: { isPresented in
                activeFilterEditor = isPresented ? editor : nil
            }
        )
    }

    @ViewBuilder
    private func filterPopoverContent(_ editor: FilterEditor) -> some View {
        switch editor {
        case .all:
            allFiltersPopover
        case .store:
            storeFilterPopover
        case .employee:
            employeeFilterPopover
        case .fromDate:
            fromDateFilterPopover
        case .toDate:
            toDateFilterPopover
        }
    }

    private var allFiltersPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Filters")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Colors.textPrimary)

            Picker("Store", selection: Binding(get: { draftStoreId ?? "" }, set: { draftStoreId = $0 })) {
                ForEach(viewModel.stores) { store in
                    Text(store.name).tag(store.id)
                }
            }
            .pickerStyle(.menu)

            Picker("Employee", selection: $draftEmployeeId) {
                ForEach(viewModel.employeeOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.menu)

            DatePicker("From", selection: $draftFromDate, displayedComponents: .date)
                .datePickerStyle(.compact)
            DatePicker("To", selection: $draftToDate, displayedComponents: .date)
                .datePickerStyle(.compact)

            Toggle("Open sessions only", isOn: $draftOpenOnly)

            HStack(spacing: DS.Spacing.s) {
                Button("Reset") {
                    resetDraftFilters()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Apply") {
                    applyDraftFiltersAndReload()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var storeFilterPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Select Store")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Colors.textPrimary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.stores) { store in
                        Button {
                            draftStoreId = store.id
                            applyDraftFiltersAndReload()
                        } label: {
                            HStack {
                                Text(store.name)
                                    .font(DS.Typography.body)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                Spacer()
                                if draftStoreId == store.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DS.Colors.primary)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(DS.Colors.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var employeeFilterPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Select Employee")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Colors.textPrimary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.employeeOptions) { option in
                        Button {
                            draftEmployeeId = option.id
                            applyDraftFiltersAndReload()
                        } label: {
                            HStack {
                                Text(option.label)
                                    .font(DS.Typography.body)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                Spacer()
                                if draftEmployeeId == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DS.Colors.primary)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(DS.Colors.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var fromDateFilterPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("From Date")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Colors.textPrimary)
            DatePicker("From", selection: $draftFromDate, displayedComponents: .date)
                .datePickerStyle(.compact)
            HStack(spacing: DS.Spacing.s) {
                Button("Today") { draftFromDate = Calendar.current.startOfDay(for: Date()) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Apply") { applyDraftFiltersAndReload() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var toDateFilterPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("To Date")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Colors.textPrimary)
            DatePicker("To", selection: $draftToDate, displayedComponents: .date)
                .datePickerStyle(.compact)
            HStack(spacing: DS.Spacing.s) {
                Button("Today") { draftToDate = Calendar.current.startOfDay(for: Date()) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Apply") { applyDraftFiltersAndReload() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func seedDraftFilters() {
        draftStoreId = viewModel.selectedStoreId
        draftEmployeeId = viewModel.selectedEmployeeId
        draftFromDate = viewModel.fromDate
        draftToDate = viewModel.toDate.addingTimeInterval(-1)
        draftOpenOnly = viewModel.showOpenSessionsOnly
    }

    private func resetDraftFilters() {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        draftFromDate = todayStart
        draftToDate = todayStart
        draftEmployeeId = ManagerCheckInsViewModel.allEmployeesId
        draftOpenOnly = false
        draftStoreId = viewModel.stores.first?.id
    }

    private func applyDraftFiltersAndReload() {
        let calendar = Calendar.current
        let normalizedFrom = calendar.startOfDay(for: draftFromDate)
        let normalizedToStart = calendar.startOfDay(for: draftToDate)
        var normalizedToExclusive = calendar.date(byAdding: .day, value: 1, to: normalizedToStart) ?? normalizedToStart

        if normalizedFrom >= normalizedToExclusive {
            normalizedToExclusive = calendar.date(byAdding: .day, value: 1, to: normalizedFrom) ?? normalizedFrom
        }

        viewModel.selectedStoreId = draftStoreId
        viewModel.selectedEmployeeId = draftEmployeeId
        viewModel.fromDate = normalizedFrom
        viewModel.toDate = normalizedToExclusive
        viewModel.showOpenSessionsOnly = draftOpenOnly
        activeFilterEditor = nil
        Task { await viewModel.load() }
    }

    private func applyDraftPreset(_ preset: ManagerCheckInsViewModel.DatePreset) {
        let calendar = Calendar.current
        let now = Date()

        switch preset {
        case .today:
            draftFromDate = calendar.startOfDay(for: now)
            draftToDate = draftFromDate
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            draftFromDate = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            draftToDate = draftFromDate
        case .last7:
            let today = calendar.startOfDay(for: now)
            draftFromDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            draftToDate = today
        case .thisWeek:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            draftFromDate = interval?.start ?? calendar.startOfDay(for: now)
            draftToDate = calendar.date(byAdding: .day, value: -1, to: (interval?.end ?? now)) ?? draftFromDate
        case .thisMonth:
            let interval = calendar.dateInterval(of: .month, for: now)
            draftFromDate = interval?.start ?? calendar.startOfDay(for: now)
            draftToDate = calendar.date(byAdding: .day, value: -1, to: (interval?.end ?? now)) ?? draftFromDate
        }
    }
}

private struct ManagerCheckInDetailView: View {
    private enum DetailField: Hashable {
        case rejectReason
    }

    let item: CheckIn
    let checkInRepository: CheckInRepositoryProtocol
    @ObservedObject var viewModel: ManagerCheckInsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editedStatus: CheckInStatus
    @State private var editedReason: String
    @State private var editedCheckInTime: Date
    @State private var editedCheckOutTime: Date
    @State private var hasCheckOutTime: Bool
    @State private var isSaving = false
    @State private var localErrorMessage: String?
    @State private var localSuccessMessage: String?
    @State private var showDeleteConfirmation = false
    @FocusState private var focusedField: DetailField?

    init(item: CheckIn, checkInRepository: CheckInRepositoryProtocol, viewModel: ManagerCheckInsViewModel) {
        self.item = item
        self.checkInRepository = checkInRepository
        self.viewModel = viewModel
        _editedStatus = State(initialValue: item.status)
        _editedReason = State(initialValue: item.rejectReason ?? "")
        _editedCheckInTime = State(initialValue: item.checkInTime)
        let checkOut = item.checkOutTime ?? Date()
        _editedCheckOutTime = State(initialValue: checkOut)
        _hasCheckOutTime = State(initialValue: item.checkOutTime != nil)
    }

    private var currentItem: CheckIn {
        viewModel.checkIns.first(where: { $0.id == item.id }) ?? item
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: currentItem.employeeName, subtitle: currentItem.storeName, icon: "person.crop.square")
                        KeyValueRow(title: "Check-In", value: currentItem.checkInTime.formatted(date: .abbreviated, time: .shortened))
                        KeyValueRow(title: "Check-Out", value: currentItem.checkOutTime?.formatted(date: .abbreviated, time: .shortened) ?? "Open")
                        KeyValueRow(title: "Status", value: currentItem.status.rawValue.capitalized)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: "Verification", subtitle: "Geo-fence evidence", icon: "location.viewfinder")
                        KeyValueRow(title: "Distance", value: "\(Int(currentItem.verifyInDistance2Meters ?? 0))m")
                        KeyValueRow(title: "Accuracy", value: "±\(Int(currentItem.verifyInAccuracy2Meters ?? 0))m")
                        KeyValueRow(title: "Drift", value: "\(Int(currentItem.verifyInDriftMeters ?? 0))m")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                editCard

                if let localSuccessMessage {
                    BannerView(text: localSuccessMessage, isError: false)
                }

                if let localErrorMessage {
                    BannerView(text: localErrorMessage, isError: true)
                }

                ManagerVerificationPhotoSection(checkIn: currentItem, checkInRepository: checkInRepository)
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppBackground())
        .navigationTitle("Check-In Detail")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
        .alert("Delete this check-in?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteCheckIn() }
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var editCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Edit Check-In", subtitle: "Adjust times and approval", icon: "pencil.and.scribble")

                Picker("Status", selection: $editedStatus) {
                    ForEach(CheckInStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(status)
                    }
                }
                .pickerStyle(.segmented)

                if editedStatus == .rejected {
                    TextField("Reject reason", text: $editedReason)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($focusedField, equals: .rejectReason)
                        .onSubmit {
                            focusedField = nil
                        }
                        .padding(.horizontal, DS.Spacing.s)
                        .frame(height: DS.Metrics.rowHeight)
                        .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                DatePicker("Check-In Time", selection: $editedCheckInTime)

                Toggle("Has check-out time", isOn: $hasCheckOutTime)
                if hasCheckOutTime {
                    DatePicker("Check-Out Time", selection: $editedCheckOutTime)
                }

                Button(isSaving ? "Saving..." : "Save Changes") {
                    Task { await saveChanges() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving)

                Button("Delete Check-In", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isSaving)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveChanges() async {
        guard !isSaving else { return }
        focusedField = nil
        isSaving = true
        defer { isSaving = false }
        localErrorMessage = nil
        localSuccessMessage = nil

        let latest = currentItem
        let targetCheckOut = hasCheckOutTime ? editedCheckOutTime : nil
        if let targetCheckOut, targetCheckOut < editedCheckInTime {
            localErrorMessage = "Check-out time cannot be earlier than check-in time."
            return
        }

        do {
            if latest.checkInTime != editedCheckInTime || latest.checkOutTime != targetCheckOut {
                try await checkInRepository.updateCheckInTimes(
                    checkIn: latest,
                    newCheckInTime: editedCheckInTime,
                    newCheckOutTime: targetCheckOut
                )
            }

            let normalizedReason = editedStatus == .rejected
                ? editedReason.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            if editedStatus == .rejected && normalizedReason.isEmpty {
                localErrorMessage = "Provide a reason when rejecting a check-in."
                return
            }

            var updated = latest
            updated.status = editedStatus
            updated.rejectReason = editedStatus == .rejected ? normalizedReason : nil

            if updated.status != latest.status || updated.rejectReason != latest.rejectReason {
                try await checkInRepository.updateCheckIn(updated)
            }

            await viewModel.load()
            localSuccessMessage = "Check-in updated."
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func deleteCheckIn() async {
        await viewModel.delete(currentItem)
        if let error = viewModel.errorMessage {
            localErrorMessage = error
        } else {
            dismiss()
        }
    }
}

private struct ManagerVerificationPhotoSection: View {
    let checkIn: CheckIn
    let checkInRepository: CheckInRepositoryProtocol

    @State private var photoData: Data?
    @State private var photoURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showFullscreen = false

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Photo Verification", subtitle: "Manager-only check-in proof", icon: "camera.viewfinder")

                if let photoData, let image = UIImage(data: photoData) {
                    Button {
                        showFullscreen = true
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if let photoURL {
                    Button {
                        showFullscreen = true
                    } label: {
                        AsyncImage(url: photoURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView("Loading photo…")
                                    .tint(DS.Colors.primary)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            case .failure:
                                Text("Photo proof is unavailable for this check-in.")
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.Colors.textSecondary)
                            @unknown default:
                                Text("Photo proof is unavailable for this check-in.")
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else if isLoading {
                    ProgressView("Loading photo…")
                        .tint(DS.Colors.primary)
                } else if let errorMessage {
                    BannerView(text: errorMessage, isError: true)
                } else {
                    Text("No photo proof is available for this check-in.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: checkIn.id) {
            await loadPhoto()
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(DS.Spacing.m)
                    } else if let photoURL {
                        AsyncImage(url: photoURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView().tint(.white)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .padding(DS.Spacing.m)
                            case .failure:
                                Text("Unable to load photo.")
                                    .foregroundStyle(.white)
                            @unknown default:
                                Text("Unable to load photo.")
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showFullscreen = false
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private func loadPhoto() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if let loadedData = try await checkInRepository.fetchVerificationPhotoData(
                checkInId: checkIn.id,
                storeId: checkIn.storeId
            ) {
                photoData = loadedData
                photoURL = nil
                errorMessage = nil
                return
            }

            if let path = checkIn.verificationPhotoPath {
                photoURL = try await checkInRepository.fetchVerificationPhotoURL(photoPath: path)
                photoData = nil
                errorMessage = nil
                return
            }

            photoData = nil
            photoURL = nil
            errorMessage = nil
        } catch {
            photoData = nil
            photoURL = nil
            errorMessage = error.localizedDescription
        }
    }
}
