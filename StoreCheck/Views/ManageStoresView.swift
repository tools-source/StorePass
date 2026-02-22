import MapKit
import SwiftUI
import UIKit

struct ManageStoresView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: StoreManagementViewModel

    @State private var name = ""
    @State private var address = ""
    @State private var latitude = 0.0
    @State private var longitude = 0.0
    @State private var radius = 150.0

    @State private var editingStore: Store?
    @State private var deletingStore: Store?
    @State private var errorMessage: String?

    private var canCreateStore: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordsSet = abs(latitude) > 0.000001 || abs(longitude) > 0.000001
        return !viewModel.isCreatingStore && !trimmedName.isEmpty && !trimmedAddress.isEmpty && coordsSet
    }

    init(repository: StoreRepositoryProtocol) {
        _viewModel = StateObject(wrappedValue: StoreManagementViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    createStoreCard
                    storeListCard
                }
                .padding(DS.Spacing.m)
            }
            .background(DS.Colors.background.ignoresSafeArea())
            .navigationTitle("Stores")
            .task { await viewModel.load(managerId: container.authRepository.currentUserId) }
            .refreshable { await viewModel.load(managerId: container.authRepository.currentUserId) }
            .sheet(item: $editingStore) { store in
                EditStoreView(store: store) { updatedStore in
                    Task {
                        await viewModel.saveStore(updatedStore)
                        await viewModel.load(managerId: container.authRepository.currentUserId)
                    }
                }
            }
            .alert(
                "Delete store",
                isPresented: Binding(get: { deletingStore != nil }, set: { if !$0 { deletingStore = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    guard let storeId = deletingStore?.id else { return }
                    Task {
                        await viewModel.deleteStore(id: storeId)
                        await viewModel.load(managerId: container.authRepository.currentUserId)
                    }
                    deletingStore = nil
                }
                Button("Cancel", role: .cancel) { deletingStore = nil }
            } message: {
                Text("This store and its member links will be removed.")
            }
            .alert("Stores", isPresented: Binding(get: { errorMessage != nil }, set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                    viewModel.clearStoreError()
                }
            })) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                    viewModel.clearStoreError()
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: viewModel.storeError) { _, newValue in
                if let newValue, !newValue.isEmpty {
                    errorMessage = newValue
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private var createStoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Store")
                    .font(.headline)
                Text("Add a location and assign its check-in radius.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Store name", text: $name)
                .textFieldStyle(.roundedBorder)

            AddressSearchField(address: $address, latitude: $latitude, longitude: $longitude)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(radius))m")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $radius, in: 50 ... 500, step: 10)
            }

            Button(viewModel.isCreatingStore ? "Creating..." : "Create") {
                Task {
                    guard canCreateStore else { return }
                    let didCreate = await viewModel.createStore(
                        name: name,
                        address: address,
                        latitude: latitude,
                        longitude: longitude,
                        radiusMeters: Int(radius)
                    )
                    await viewModel.load(managerId: container.authRepository.currentUserId)
                    if didCreate {
                        await MainActor.run {
                            name = ""
                            address = ""
                            latitude = 0
                            longitude = 0
                            radius = 150
                        }
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canCreateStore)
            .opacity(canCreateStore ? 1 : 0.6)
        }
        .padding(DS.Spacing.m)
        .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var storeListCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Store List")
                .font(.headline)

            if viewModel.stores.isEmpty {
                Text("No stores yet")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.stores) { store in
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.name)
                        .font(.headline)

                    Text(store.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(store.radiusMeters)m radius • code ending ••••\(store.joinCodeLast4 ?? "----")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            actionButton("Copy code", icon: "doc.on.doc", prominence: .secondary) {
                                Task {
                                    if let cached = viewModel.latestJoinCodesByStoreId[store.id] {
                                        UIPasteboard.general.string = cached
                                        viewModel.showToast("Code copied")
                                    } else {
                                        let fetched = await viewModel.fetchJoinCode(storeId: store.id)
                                        if let fetched {
                                            UIPasteboard.general.string = fetched
                                            viewModel.showToast("Code copied")
                                        } else {
                                            await MainActor.run {
                                                viewModel.presentStoreError("Unable to fetch store code.")
                                            }
                                        }
                                    }
                                }
                            }

                            actionButton("Rotate code", icon: "arrow.triangle.2.circlepath", prominence: .primary) {
                                Task {
                                    await viewModel.rotateStoreCode(storeId: store.id)
                                    if let newCode = viewModel.latestJoinCodesByStoreId[store.id] {
                                        UIPasteboard.general.string = newCode
                                        viewModel.showToast("New code copied")
                                    }
                                    await viewModel.load(managerId: container.authRepository.currentUserId)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            actionButton("Edit", icon: "pencil", prominence: .secondary) {
                                editingStore = store
                            }

                            actionButton("Delete", icon: "trash", prominence: .destructive) {
                                deletingStore = store
                            }
                        }
                    }
                }
                .padding(.vertical, 6)

                if store.id != viewModel.stores.last?.id {
                    Color.clear
                        .frame(height: 2)
                }
            }
        }
        .cardStyle()
    }

    private enum StoreActionProminence {
        case primary
        case secondary
        case destructive
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        icon: String,
        prominence: StoreActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        let foreground: Color = prominence == .destructive ? .red : .white
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .padding(.vertical, 9)
        .background(buttonBackground(for: prominence), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke(for: prominence), lineWidth: 1)
        }
    }

    private func buttonBackground(for prominence: StoreActionProminence) -> Color {
        switch prominence {
        case .primary:
            return DS.Colors.primary.opacity(0.95)
        case .secondary:
            return .white.opacity(0.04)
        case .destructive:
            return .red.opacity(0.08)
        }
    }

    private func buttonStroke(for prominence: StoreActionProminence) -> Color {
        switch prominence {
        case .primary:
            return .clear
        case .secondary:
            return .white.opacity(0.1)
        case .destructive:
            return .red.opacity(0.35)
        }
    }
}

@MainActor
final class AddressSearchService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published var suggestions: [MKLocalSearchCompletion] = []

    private var suppressNextResults = false
    private var lastSelectedQuery: String?

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        if suppressNextResults {
            suppressNextResults = false
            suggestions = []
            return
        }

        if let lastSelectedQuery,
           query.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(lastSelectedQuery.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            suggestions = []
            return
        }

        suggestions = completer.results
    }

    func select(_ completion: MKLocalSearchCompletion) async -> (String, CLLocationCoordinate2D)? {
        let request = MKLocalSearch.Request(completion: completion)
        let response = try? await MKLocalSearch(request: request).start()
        guard let item = response?.mapItems.first else { return nil }
        return (item.placemark.title ?? completion.title, item.placemark.coordinate)
    }

    func markSelection(_ selectedQuery: String) {
        lastSelectedQuery = selectedQuery
        suppressNextResults = true
        suggestions = []
    }
}

struct AddressSearchField: View {
    @Binding var address: String
    @Binding var latitude: Double
    @Binding var longitude: Double

    @StateObject private var search = AddressSearchService()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search address", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            if !search.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(search.suggestions.prefix(5), id: \.self) { suggestion in
                        Button {
                            Task {
                                guard let resolved = await search.select(suggestion) else { return }
                                await MainActor.run {
                                    address = resolved.0
                                    latitude = resolved.1.latitude
                                    longitude = resolved.1.longitude
                                    search.markSelection(resolved.0)
                                    search.query = resolved.0
                                    isFocused = false
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }

            Text("Lat: \(latitude, specifier: "%.5f"), Lng: \(longitude, specifier: "%.5f")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if !address.isEmpty, search.query.isEmpty {
                search.query = address
            }
        }
        .onChange(of: address) { _, newValue in
            if search.query != newValue {
                search.query = newValue
            }

            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                search.suggestions = []
                isFocused = false
            }
        }
    }
}

private struct EditStoreView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var store: Store
    @State private var address: String
    @State private var latitude: Double
    @State private var longitude: Double

    let onSave: (Store) -> Void

    init(store: Store, onSave: @escaping (Store) -> Void) {
        _store = State(initialValue: store)
        _address = State(initialValue: store.address)
        _latitude = State(initialValue: store.latitude)
        _longitude = State(initialValue: store.longitude)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Store") {
                    TextField("Store name", text: $store.name)
                    AddressSearchField(address: $address, latitude: $latitude, longitude: $longitude)
                    TextField("Latitude", value: $latitude, format: .number)
                    TextField("Longitude", value: $longitude, format: .number)
                    Stepper("Radius \(store.radiusMeters)m", value: $store.radiusMeters, in: 50 ... 600, step: 10)
                }
            }
            .navigationTitle("Edit Store")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.address = address
                        store.latitude = latitude
                        store.longitude = longitude
                        onSave(store)
                        dismiss()
                    }
                }
            }
        }
    }
}
