import MapKit
import SwiftUI
import UIKit

struct ManageStoresView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var vm: StoreManagementViewModel

    @State private var name = ""
    @State private var address = ""
    @State private var latitude = 0.0
    @State private var longitude = 0.0
    @State private var radius = 150.0

    @State private var editingStore: Store?
    @State private var deletingStore: Store?

    init(repository: StoreRepositoryProtocol) {
        _vm = StateObject(wrappedValue: StoreManagementViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    createCard
                    storesCard
                }
                .padding(DS.Spacing.m)
            }
            .background(DS.Colors.background.ignoresSafeArea())
            .navigationTitle("Stores")
            .task { await vm.load(managerId: container.authRepository.currentUserId) }
            .refreshable { await vm.load(managerId: container.authRepository.currentUserId) }
            .sheet(item: $editingStore) { store in
                EditStoreView(store: store) { updated in
                    Task {
                        await vm.saveStore(updated)
                        await vm.load(managerId: container.authRepository.currentUserId)
                    }
                }
            }
            .alert(
                "Delete store",
                isPresented: Binding(
                    get: { deletingStore != nil },
                    set: { if !$0 { deletingStore = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let id = deletingStore?.id {
                        Task {
                            await vm.deleteStore(id: id)
                            await vm.load(managerId: container.authRepository.currentUserId)
                        }
                    }
                    deletingStore = nil
                }
                Button("Cancel", role: .cancel) { deletingStore = nil }
            } message: {
                Text("This will remove the store and stop new joins.")
            }
            .alert(
                "Store tools",
                isPresented: Binding(
                    get: { vm.errorMessage != nil },
                    set: { _ in vm.errorMessage = nil }
                )
            ) {
                Button("OK", role: .cancel) { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let toast = vm.toastMessage {
                    Text(toast)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                vm.toastMessage = nil
                            }
                        }
                }
            }
        }
    }

    private var createCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Create Store").font(.headline)

            TextField("Store name", text: $name)
                .textFieldStyle(.roundedBorder)

            AddressSearchField(address: $address, latitude: $latitude, longitude: $longitude)

            VStack(alignment: .leading) {
                Text("Radius: \(Int(radius))m")
                Slider(value: $radius, in: 50...500, step: 10)
            }

            Button("Create Store") {
                Task {
                    await vm.createStore(
                        name: name,
                        address: address,
                        latitude: latitude,
                        longitude: longitude,
                        radiusMeters: Int(radius)
                    )
                    await vm.load(managerId: container.authRepository.currentUserId)
                    name = ""
                    address = ""
                    latitude = 0
                    longitude = 0
                    radius = 150
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
        }
        .cardStyle()
    }

    private var storesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Store List").font(.headline)

            if vm.stores.isEmpty {
                Text("No stores yet").foregroundStyle(.secondary)
            }

            ForEach(vm.stores) { store in
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.name).font(.headline)
                    Text(store.address).font(.caption).foregroundStyle(.secondary)
                    Text("\(store.radiusMeters)m radius • code ending ••••\(store.joinCodeLast4 ?? "----")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Copy code") {
                            Task {
                                // ✅ FIX: avoid using `await` inside `??` (autoclosure)
                                let cached = vm.latestJoinCodesByStoreId[store.id]
                                let code: String?

                                if let cached {
                                    code = cached
                                } else {
                                    code = await vm.fetchJoinCode(storeId: store.id)
                                }

                                if let code {
                                    UIPasteboard.general.string = code
                                    vm.toastMessage = "Code copied"
                                } else {
                                    vm.errorMessage = "Unable to fetch store code."
                                }
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Rotate code") {
                            Task {
                                await vm.rotateStoreCode(storeId: store.id)

                                if let code = vm.latestJoinCodesByStoreId[store.id] {
                                    UIPasteboard.general.string = code
                                    vm.toastMessage = "New code copied"
                                }

                                await vm.load(managerId: container.authRepository.currentUserId)
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Menu {
                            Button("Edit") { editingStore = store }
                            Button("Delete", role: .destructive) { deletingStore = store }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }

                if store.id != vm.stores.last?.id {
                    Divider().overlay(.white.opacity(0.15))
                }
            }
        }
        .cardStyle()
    }
}

private final class AddressSearchService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" { didSet { completer.queryFragment = query } }
    @Published var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    func select(_ completion: MKLocalSearchCompletion) async -> (String, CLLocationCoordinate2D)? {
        let request = MKLocalSearch.Request(completion: completion)
        let response = try? await MKLocalSearch(request: request).start()
        guard let item = response?.mapItems.first else { return nil }
        return (item.placemark.title ?? completion.title, item.placemark.coordinate)
    }
}

private struct AddressSearchField: View {
    @Binding var address: String
    @Binding var latitude: Double
    @Binding var longitude: Double
    @StateObject private var search = AddressSearchService()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search address", text: $search.query)
                .textFieldStyle(.roundedBorder)

            if !search.suggestions.isEmpty {
                ForEach(search.suggestions.prefix(5), id: \.self) { suggestion in
                    Button {
                        Task {
                            if let resolved = await search.select(suggestion) {
                                address = resolved.0
                                latitude = resolved.1.latitude
                                longitude = resolved.1.longitude
                                search.query = resolved.0
                                search.suggestions = []
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
                }
            }

            TextField("Address (manual override)", text: $address)
                .textFieldStyle(.roundedBorder)

            Text("Lat: \(latitude, specifier: "%.5f"), Lng: \(longitude, specifier: "%.5f")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EditStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @State var store: Store
    let onSave: (Store) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Store name", text: $store.name)
                TextField("Address", text: $store.address)
                TextField("Latitude", value: $store.latitude, format: .number)
                TextField("Longitude", value: $store.longitude, format: .number)
                Stepper("Radius \(store.radiusMeters)m", value: $store.radiusMeters, in: 50...600, step: 10)
            }
            .navigationTitle("Edit Store")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(store)
                        dismiss()
                    }
                }
            }
        }
    }
}
