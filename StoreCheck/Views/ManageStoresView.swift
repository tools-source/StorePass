import SwiftUI

struct ManageStoresView: View {
    @StateObject private var vm = StoreManagementViewModel(repository: AppContainer.shared.storeRepository)
    @State private var name = ""
    @State private var address = ""
    @State private var lat = ""
    @State private var lng = ""
    @State private var radius = 150.0

    var body: some View {
        StoresView(viewModel: vm, name: $name, address: $address, lat: $lat, lng: $lng, radius: $radius)
    }
}

struct StoresView: View {
    @ObservedObject var viewModel: StoreManagementViewModel
    @Binding var name: String
    @Binding var address: String
    @Binding var lat: String
    @Binding var lng: String
    @Binding var radius: Double

    var body: some View {
        NavigationStack {
            Form {
                Section("Create / Edit Store") {
                    TextField("Name", text: $name)
                    TextField("Address", text: $address)
                    TextField("Latitude", text: $lat)
                    TextField("Longitude", text: $lng)
                    VStack(alignment: .leading) {
                        Text("Radius: \(Int(radius))m")
                        Slider(value: $radius, in: 50...500, step: 10)
                    }
                    Button("Save Store") {
                        Task {
                            let store = Store(id: UUID().uuidString, name: name, address: address, lat: Double(lat) ?? 0, lng: Double(lng) ?? 0, radiusMeters: Int(radius), isActive: true)
                            await viewModel.save(store: store)
                        }
                    }
                }

                Section("Stores") {
                    if viewModel.stores.isEmpty {
                        Text("No stores yet")
                    } else {
                        ForEach(viewModel.stores) { store in
                            VStack(alignment: .leading) {
                                Text(store.name)
                                Text("\(store.address) • \(store.radiusMeters)m")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Stores")
            .task { await viewModel.load() }
        }
    }
}
