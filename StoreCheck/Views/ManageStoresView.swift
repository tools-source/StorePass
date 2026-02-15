import MapKit
import SwiftUI

struct ManageStoresView: View {
    @StateObject private var vm = StoreManagementViewModel(repository: AppContainer.shared.storeRepository)
    @State private var name = ""
    @State private var address = ""
    @State private var lat = "37.3349"
    @State private var lng = "-122.0090"
    @State private var radius = "150"

    var body: some View {
        NavigationStack {
            VStack {
                Form {
                    TextField("Store Name", text: $name)
                    TextField("Address", text: $address)
                    TextField("Latitude", text: $lat)
                    TextField("Longitude", text: $lng)
                    TextField("Radius (m)", text: $radius)
                    Button("Save Store") {
                        Task {
                            let store = Store(
                                id: UUID().uuidString,
                                name: name,
                                address: address,
                                lat: Double(lat) ?? 0,
                                lng: Double(lng) ?? 0,
                                radiusMeters: Double(radius) ?? 150,
                                isActive: true,
                                createdAt: Date()
                            )
                            await vm.save(store: store)
                        }
                    }
                }
                List(vm.stores) { store in
                    VStack(alignment: .leading) {
                        Text(store.name).font(.headline)
                        Text("\(store.address) • r=\(Int(store.radiusMeters))m")
                    }
                }
            }
            .navigationTitle("Manage Stores")
            .task { await vm.load() }
        }
    }
}
