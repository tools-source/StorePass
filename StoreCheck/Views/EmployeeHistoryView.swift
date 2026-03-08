import SwiftUI

struct EmployeeHistoryView: View {
    @StateObject private var vm: EmployeeHistoryViewModel
    @State private var pendingDelete: CheckIn?

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        _vm = StateObject(wrappedValue: EmployeeHistoryViewModel(
            authService: authService,
            checkInRepository: checkInRepository,
            csvExporter: csvExporter
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        ScreenHeader(
                            title: "History",
                            subtitle: "Review sessions and timesheet totals",
                            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                        )

                        summaryCard

                        if let error = vm.errorMessage {
                            BannerView(text: error, isError: true)
                        }

                        if vm.visibleCheckIns.isEmpty {
                            EmptyStateView(
                                icon: "clock.badge.xmark",
                                title: "No sessions for this filter",
                                message: "Try another date or store to view completed shifts."
                            )
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(vm.visibleCheckIns) { item in
                                    NavigationLink {
                                        EmployeeCheckInDetailView(checkIn: item)
                                    } label: {
                                        historyRow(item)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            vm.copySingle(item)
                                        } label: {
                                            Label("Copy CSV", systemImage: "doc.on.doc")
                                        }
                                        .tint(DS.Colors.primary)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDelete = item
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let exportURL = vm.exportURL() {
                        ShareLink(item: exportURL)
                    }
                }
            }
            .task { await vm.load() }
            .refreshable { await vm.load() }
            .alert(
                "Delete Session",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    guard let pendingDelete else { return }
                    Task { await vm.delete(pendingDelete) }
                    self.pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                Text("This permanently removes the selected attendance record.")
            }
        }
    }

    private var summaryCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Timesheet Summary", subtitle: "Filter and totals", icon: "calendar")

                DatePicker("Date", selection: $vm.selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)

                if vm.hasMultipleStores {
                    Picker("Store", selection: Binding(
                        get: { vm.selectedStoreId ?? "" },
                        set: { vm.selectedStoreId = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(vm.storeOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: DS.Spacing.s) {
                    MetricChip(label: "Sessions", value: "\(vm.visibleCheckIns.count)", icon: "list.number")
                    MetricChip(label: "Total", value: vm.formattedDuration(seconds: vm.dailyTotalSeconds), icon: "hourglass")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyRow(_ item: CheckIn) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(item.storeName)
                            .font(DS.Typography.headline)
                            .foregroundStyle(DS.Colors.textPrimary)

                        Text("\(item.checkInTime.formatted(date: .abbreviated, time: .shortened)) → \(item.checkOutTime?.formatted(date: .omitted, time: .shortened) ?? "Open")")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }

                    Spacer(minLength: 0)

                    StatBadge(style: item.status == .approved ? .approved : .rejected)
                }

                Divider()

                KeyValueRow(title: "Duration", value: vm.formattedDuration(seconds: item.computedDurationSeconds ?? 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmployeeCheckInDetailView: View {
    let checkIn: CheckIn

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: checkIn.storeName, subtitle: "Session details", icon: "building.2")
                        KeyValueRow(title: "Check-In", value: checkIn.checkInTime.formatted(date: .abbreviated, time: .shortened))
                        KeyValueRow(title: "Check-Out", value: checkIn.checkOutTime?.formatted(date: .abbreviated, time: .shortened) ?? "Open")
                        KeyValueRow(title: "Duration", value: DurationFormatter.clockString(from: checkIn.computedDurationSeconds ?? 0))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: "Verification", subtitle: "Geo-fence evidence", icon: "checkmark.shield")
                        detail("Distance", "\(Int(checkIn.verifyInDistance2Meters ?? 0))m")
                        detail("Accuracy", "±\(Int(checkIn.verifyInAccuracy2Meters ?? 0))m")
                        detail("Drift", "\(Int(checkIn.verifyInDriftMeters ?? 0))m")
                        detail("Coordinates", String(format: "%.5f, %.5f", checkIn.clientLat, checkIn.clientLng))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text("Session ID")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                        Text(checkIn.id)
                            .font(DS.Typography.mono)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.m)
        }
        .background(AppBackground())
        .navigationTitle("Session Detail")
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
