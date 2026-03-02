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
        NavigationStack {
            Group {
                if vm.visibleCheckIns.isEmpty {
                    EmptyStateView(icon: "clock.badge.xmark", title: "No History Yet", message: "Your check-in sessions will appear here.")
                        .padding(.horizontal, DS.Spacing.m)
                } else {
                    List(vm.visibleCheckIns) { item in
                        NavigationLink {
                            EmployeeCheckInDetailView(checkIn: item)
                        } label: {
                            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                                HStack {
                                    Text(item.storeName).font(.headline)
                                    Spacer()
                                    StatBadge(style: item.verifyInInside == true ? .inside : .outside)
                                    StatBadge(style: item.status == .approved ? .approved : .rejected)
                                }
                                Text("\(item.checkInTime.formatted(date: .abbreviated, time: .shortened)) → \(item.checkOutTime?.formatted(date: .omitted, time: .shortened) ?? "Open")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Duration: \(vm.formattedDuration(seconds: item.computedDurationSeconds ?? 0))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(DS.Colors.card)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(DS.Colors.background)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { vm.copyAllVisible() } label: { Image(systemName: "doc.on.doc") }
                }
            }
            .task { await vm.load() }
            .refreshable { await vm.load() }
        }
    }
}

private struct EmployeeCheckInDetailView: View {
    let checkIn: CheckIn
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text(checkIn.storeName).font(.headline)
                        Text("\(checkIn.clientLat, format: .number.precision(.fractionLength(5))), \(checkIn.clientLng, format: .number.precision(.fractionLength(5)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text("Verification").font(.headline)
                        detail("Distance", "\(Int(checkIn.verifyInDistance2Meters ?? 0))m")
                        detail("Accuracy", "±\(Int(checkIn.verifyInAccuracy2Meters ?? 0))m")
                        detail("Drift", "\(Int(checkIn.verifyInDriftMeters ?? 0))m")
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Text("Check-in ID: \(checkIn.id)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.horizontal, DS.Spacing.s)
            }
            .padding(DS.Spacing.m)
        }
        .navigationTitle("Session Details")
        .background(DS.Colors.background)
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
}
