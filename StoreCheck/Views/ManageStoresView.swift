import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI
import UIKit

struct ManageStoresView: View {
    private enum FormField: Hashable {
        case name
        case address
        case latitude
        case longitude
        case radius
    }

    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: StoreManagementViewModel
    @StateObject private var addressSearch = StoreAddressSearchModel()

    @State private var name = ""
    @State private var address = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var radiusText = "150"
    @State private var isApplyingAddressSelection = false
    @State private var isResolvingAddress = false
    @State private var isCreateStoreFormExpanded = true
    @State private var didAutoConfigureCreateStoreForm = false
    @FocusState private var focusedField: FormField?

    @State private var deletingStore: Store?

    init(repository: StoreRepositoryProtocol) {
        _viewModel = StateObject(wrappedValue: StoreManagementViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        ScreenHeader(
                            title: "Stores",
                            subtitle: "Create and manage geofenced work locations",
                            icon: "building.2"
                        )

                        summaryCard
                        createStoreCard

                        if viewModel.stores.isEmpty, viewModel.storeError == nil {
                            EmptyStateView(
                                icon: "building.2.crop.circle",
                                title: "No stores yet",
                                message: "Create your first store to onboard employees with join codes."
                            )
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(viewModel.stores) { store in
                                    NavigationLink {
                                        StoreDetailView(
                                            storeId: store.id,
                                            viewModel: viewModel,
                                            managerId: container.authRepository.currentUserId,
                                            onDelete: { deletingStore = store }
                                        )
                                    } label: {
                                        storeRow(store)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            Task {
                                                await viewModel.rotateStoreCode(
                                                    storeId: store.id,
                                                    managerId: container.authRepository.currentUserId
                                                )
                                            }
                                        } label: {
                                            Label("Rotate Code", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        .tint(DS.Colors.primary)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            deletingStore = store
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }

                        if let error = viewModel.storeError {
                            BannerView(text: error, isError: true)
                        }
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Stores")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .task { await viewModel.load(managerId: container.authRepository.currentUserId) }
            .refreshable { await viewModel.load(managerId: container.authRepository.currentUserId) }
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                Task { await viewModel.load(managerId: container.authRepository.currentUserId) }
            }
            .onChange(of: viewModel.stores.count) { _, count in
                guard !didAutoConfigureCreateStoreForm else { return }
                isCreateStoreFormExpanded = count == 0
                didAutoConfigureCreateStoreForm = true
            }
            .alert(
                "Delete Store",
                isPresented: Binding(get: { deletingStore != nil }, set: { if !$0 { deletingStore = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    guard let store = deletingStore else { return }
                    Task {
                        await viewModel.deleteStore(id: store.id)
                    }
                    deletingStore = nil
                }
                Button("Cancel", role: .cancel) { deletingStore = nil }
            } message: {
                Text("Employees will lose access to this store immediately.")
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .font(DS.Typography.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(DS.Colors.card.opacity(0.95), in: Capsule())
                        .padding(.bottom, 22)
                }
            }
        }
    }

    private var summaryCard: some View {
        CardView {
            HStack(spacing: DS.Spacing.s) {
                MetricChip(label: "Total Stores", value: "\(viewModel.stores.count)", icon: "building.2")
                MetricChip(label: "Default Radius", value: "\(radiusText)m", icon: "scope")
            }
        }
    }

    private var createStoreCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCreateStoreFormExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: DS.Spacing.s) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(DS.Colors.primaryGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text("Create Store")
                                .font(DS.Typography.title)
                                .foregroundStyle(DS.Colors.textPrimary)
                            Text("Set location and radius used for attendance validation.")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: isCreateStoreFormExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(DS.Colors.primary)
                    }
                }
                .buttonStyle(.plain)

                if isCreateStoreFormExpanded {
                    Group {
                        entryField(title: "Store name", text: $name, keyboard: .default, accessibilityID: "store_name_input", focus: .name, submitLabel: .next, nextFocus: .address)
                        addressEntrySection

                        HStack(spacing: DS.Spacing.s) {
                            entryField(title: "Latitude", text: $latitudeText, keyboard: .numbersAndPunctuation, accessibilityID: "store_lat_input", focus: .latitude, submitLabel: .next, nextFocus: .longitude)
                            entryField(title: "Longitude", text: $longitudeText, keyboard: .numbersAndPunctuation, accessibilityID: "store_lng_input", focus: .longitude, submitLabel: .next, nextFocus: .radius)
                        }

                        entryField(title: "Radius (meters)", text: $radiusText, keyboard: .numberPad, accessibilityID: "store_radius_input", focus: .radius)
                    }

                    Button(viewModel.isCreatingStore ? "Creating..." : "Create Store") {
                        Task {
                            focusedField = nil
                            await createStore()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isCreatingStore)
                    .accessibilityIdentifier("create_store_button")
                } else {
                    Text("Collapsed. Tap to expand and create a new store.")
                        .font(DS.Typography.micro)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
    }

    private var addressEntrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address")
                .font(DS.Typography.micro)
                .foregroundStyle(DS.Colors.textSecondary)

            TextField("Address", text: $address)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .address)
                .padding(.horizontal, DS.Spacing.s)
                .frame(height: DS.Metrics.rowHeight)
                .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("store_address_input")
                .onSubmit {
                    focusedField = .latitude
                }
                .onChange(of: address) { _, newValue in
                    if isApplyingAddressSelection {
                        isApplyingAddressSelection = false
                        return
                    }
                    addressSearch.updateQuery(newValue)
                }

            if isResolvingAddress {
                HStack(spacing: DS.Spacing.xs) {
                    ProgressView()
                        .tint(DS.Colors.primary)
                    Text("Resolving address coordinates...")
                        .font(DS.Typography.micro)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .padding(.horizontal, DS.Spacing.xs)
            }

            if !addressSearch.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(addressSearch.suggestions) { suggestion in
                        Button {
                            Task { await applyAddressSuggestion(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.title)
                                    .font(DS.Typography.caption.weight(.semibold))
                                    .foregroundStyle(DS.Colors.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(DS.Typography.micro)
                                        .foregroundStyle(DS.Colors.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.s)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != addressSearch.suggestions.last?.id {
                            Divider()
                        }
                    }
                }
                .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.Colors.separator, lineWidth: 1)
                }
            }
        }
    }

    private func storeRow(_ store: Store) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(store.name)
                            .font(DS.Typography.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(store.address)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    StatBadge(style: .neutral, text: "\(store.radiusMeters)m")
                }

                Divider()

                KeyValueRow(title: "Join code", value: viewModel.resolvedJoinCode(for: store))
                KeyValueRow(title: "QR check-in", value: store.qrCheckInEnabled ? "Enabled" : "Disabled")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func entryField(
        title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        accessibilityID: String,
        focus: FormField = .name,
        submitLabel: SubmitLabel = .done,
        nextFocus: FormField? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DS.Typography.micro)
                .foregroundStyle(DS.Colors.textSecondary)

            TextField(title, text: text)
                .keyboardType(keyboard)
                .submitLabel(submitLabel)
                .focused($focusedField, equals: focus)
                .onSubmit {
                    focusedField = nextFocus
                }
                .padding(.horizontal, DS.Spacing.s)
                .frame(height: DS.Metrics.rowHeight)
                .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier(accessibilityID)
        }
    }

    private func applyAddressSuggestion(_ suggestion: StoreAddressSuggestion) async {
        isResolvingAddress = true
        defer { isResolvingAddress = false }

        do {
            let resolved = try await addressSearch.resolveSuggestion(suggestion)
            isApplyingAddressSelection = true
            address = resolved.displayText
            latitudeText = String(format: "%.6f", resolved.coordinate.latitude)
            longitudeText = String(format: "%.6f", resolved.coordinate.longitude)
            addressSearch.clear()
            viewModel.clearStoreError()
        } catch {
            viewModel.presentStoreError("Unable to resolve that address. Choose a different result or enter coordinates manually.")
            AppLog.error("Failed resolving store address", error: error)
        }
    }

    private func createStore() async {
        guard let latitude = Double(latitudeText),
              let longitude = Double(longitudeText),
              let radius = Int(radiusText) else {
            viewModel.presentStoreError("Latitude, longitude, and radius must be valid numbers.")
            return
        }

        let created = await viewModel.createStore(
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radius
        )

        if created {
            await viewModel.load(managerId: container.authRepository.currentUserId)
            name = ""
            address = ""
            latitudeText = ""
            longitudeText = ""
            radiusText = "150"
            withAnimation(.easeInOut(duration: 0.2)) {
                isCreateStoreFormExpanded = false
            }
        }
    }
}

private struct StoreAddressSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}

private struct ResolvedStoreAddress {
    let displayText: String
    let coordinate: CLLocationCoordinate2D
}

@MainActor
private final class StoreAddressSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [StoreAddressSuggestion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }

        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let resolvedSuggestions = completer.results.prefix(5).map {
            StoreAddressSuggestion(
                id: "\($0.title)|\($0.subtitle)",
                title: $0.title,
                subtitle: $0.subtitle
            )
        }
        Task { @MainActor in
            suggestions = resolvedSuggestions
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            suggestions = []
            AppLog.warning("Address completer failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    func resolveSuggestion(_ suggestion: StoreAddressSuggestion) async throws -> ResolvedStoreAddress {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NSError(
                domain: "StorePass",
                code: 6201,
                userInfo: [NSLocalizedDescriptionKey: "No location was returned for that address."]
            )
        }

        let displayText = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        return ResolvedStoreAddress(
            displayText: displayText,
            coordinate: item.placemark.coordinate
        )
    }
}

private struct StoreDetailView: View {
    let storeId: String
    @ObservedObject var viewModel: StoreManagementViewModel
    let managerId: String?
    let onDelete: () -> Void

    @State private var isRotatingJoinCode = false
    @State private var isRotatingQRCode = false
    @State private var broadcastDraft = ""

    private let qrContext = CIContext()

    private var store: Store? {
        viewModel.stores.first(where: { $0.id == storeId })
    }

    private var trimmedBroadcastDraft: String {
        broadcastDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var broadcastCharacterCount: Int {
        trimmedBroadcastDraft.count
    }

    private var messages: [BroadcastMessage] {
        viewModel.broadcastMessages(for: storeId)
    }

    var body: some View {
        ScrollView {
            if let store {
                VStack(spacing: DS.Spacing.m) {
                    CardView {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            ScreenHeader(title: store.name, subtitle: store.address, icon: "mappin.circle")
                            KeyValueRow(title: "Latitude", value: String(format: "%.6f", store.latitude))
                            KeyValueRow(title: "Longitude", value: String(format: "%.6f", store.longitude))
                            KeyValueRow(title: "Radius", value: "\(store.radiusMeters)m")
                            KeyValueRow(title: "Time Zone", value: store.timeZoneIdentifier)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    joinCodeCard(store: store)
                    qrCodeCard(store: store)
                    broadcastCard(store: store)

                    CardView {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            ScreenHeader(title: "Danger Zone", subtitle: "Permanent store removal", icon: "trash")

                            Button("Delete Store", role: .destructive) {
                                onDelete()
                            }
                            .buttonStyle(DestructiveButtonStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: DS.Metrics.maxReadableWidth)
                .padding(.horizontal, DS.Spacing.m)
                .padding(.vertical, DS.Spacing.m)
            } else {
                VStack {
                    EmptyStateView(
                        icon: "building.2.crop.circle",
                        title: "Store unavailable",
                        message: "This store could not be loaded. Pull to refresh and try again."
                    )
                }
                .frame(maxWidth: DS.Metrics.maxReadableWidth)
                .padding(.horizontal, DS.Spacing.m)
                .padding(.vertical, DS.Spacing.m)
            }
        }
        .background(AppBackground())
        .navigationTitle(store?.name ?? "Store Detail")
        .task(id: storeId) {
            _ = await viewModel.fetchJoinCode(storeId: storeId)
            await viewModel.loadBroadcastMessages(storeId: storeId)
        }
    }

    @ViewBuilder
    private func joinCodeCard(store: Store) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Join Code", subtitle: "Use this code to join the store", icon: "number")

                Text(viewModel.resolvedJoinCode(for: store))
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(DS.Colors.textPrimary)

                HStack(spacing: DS.Spacing.s) {
                    Button("Copy") {
                        UIPasteboard.general.string = viewModel.resolvedJoinCode(for: store)
                        viewModel.showToast("Join code copied")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button(isRotatingJoinCode ? "Rotating..." : "Rotate") {
                        Task {
                            isRotatingJoinCode = true
                            await viewModel.rotateStoreCode(storeId: store.id, managerId: managerId)
                            isRotatingJoinCode = false
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isRotatingJoinCode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func qrCodeCard(store: Store) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(
                    title: "QR Check-In",
                    subtitle: "Employees can scan this code to check in.",
                    icon: "qrcode.viewfinder"
                )

                Toggle(
                    "Enable QR check-in",
                    isOn: Binding(
                        get: { store.qrCheckInEnabled },
                        set: { isEnabled in
                            Task {
                                await viewModel.setQRCodeMode(storeId: store.id, isEnabled: isEnabled)
                            }
                        }
                    )
                )
                .disabled(viewModel.isUpdatingStoreSettings)

                if store.qrCheckInEnabled {
                    if let payload = qrCheckInPayload(for: store),
                       let qrImage = qrImage(from: payload) {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(height: 220)
                                .padding(DS.Spacing.s)
                                .background(DS.Colors.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            Text(payload)
                                .font(DS.Typography.micro)
                                .foregroundStyle(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("QR check-in is enabled, but this store does not have a valid QR token yet.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }

                    HStack(spacing: DS.Spacing.s) {
                        Button("Copy QR Link") {
                            if let payload = qrCheckInPayload(for: store) {
                                UIPasteboard.general.string = payload
                                viewModel.showToast("QR link copied")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button(isRotatingQRCode ? "Refreshing..." : "Refresh QR") {
                            Task {
                                isRotatingQRCode = true
                                _ = await viewModel.rotateQRCode(storeId: store.id)
                                isRotatingQRCode = false
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isRotatingQRCode || viewModel.isUpdatingStoreSettings)
                    }
                } else {
                    Text("QR mode is disabled. Employees can still use regular geofence check-in.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func broadcastCard(store: Store) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(
                    title: "Broadcast",
                    subtitle: "Send a message to everyone assigned to this store.",
                    icon: "megaphone"
                )

                TextEditor(text: $broadcastDraft)
                    .font(DS.Typography.body)
                    .frame(minHeight: 96)
                    .padding(DS.Spacing.xs)
                    .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(DS.Colors.separator, lineWidth: 1)
                    }

                HStack(spacing: DS.Spacing.s) {
                    Text("\(broadcastCharacterCount)/500")
                        .font(DS.Typography.micro)
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button(viewModel.isSendingBroadcast ? "Sending..." : "Send Broadcast") {
                        Task {
                            let didSend = await viewModel.sendBroadcast(storeId: store.id, message: broadcastDraft)
                            if didSend {
                                broadcastDraft = ""
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isSendingBroadcast || trimmedBroadcastDraft.isEmpty || broadcastCharacterCount > 500)
                    .frame(maxWidth: 220)
                }

                Divider()

                if messages.isEmpty {
                    Text("No broadcast history yet.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(messages.prefix(8)) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: DS.Spacing.s) {
                                    Text(message.managerName)
                                        .font(DS.Typography.micro.weight(.semibold))
                                        .foregroundStyle(DS.Colors.textSecondary)
                                    Spacer()
                                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DS.Typography.micro)
                                        .foregroundStyle(DS.Colors.textSecondary)
                                }

                                Text(message.message)
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.Colors.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(DS.Colors.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func qrCheckInPayload(for store: Store) -> String? {
        guard let token = store.qrCodeToken, !token.isEmpty else { return nil }
        return "storepass://checkin?storeId=\(store.id)&token=\(token)"
    }

    private func qrImage(from payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = qrContext.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
