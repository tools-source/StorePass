import SwiftUI
import UIKit

struct ManageStoresView: View {
    @StateObject private var vm: StoreManagementViewModel
    @State private var name = ""
    @State private var address = ""
    @State private var lat = ""
    @State private var lng = ""
    @State private var radius = 150.0

    init(repository: StoreRepositoryProtocol) {
        _vm = StateObject(wrappedValue: StoreManagementViewModel(repository: repository))
    }

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

    @State private var shareText = ""
    @State private var showShareSheet = false
    @State private var latestCodeBanner: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Create Store") {
                    TextField("Name", text: $name)
                    TextField("Address", text: $address)
                    TextField("Latitude", text: $lat)
                    TextField("Longitude", text: $lng)
                    VStack(alignment: .leading) {
                        Text("Radius: \(Int(radius))m")
                        Slider(value: $radius, in: 50...500, step: 10)
                    }
                    Button("Create Store") {
                        Task {
                            await viewModel.createStore(
                                name: name,
                                address: address,
                                lat: Double(lat) ?? 0,
                                lng: Double(lng) ?? 0,
                                radiusMeters: Int(radius)
                            )

                            if let createdStoreId = viewModel.lastCreatedStoreId,
                               let code = viewModel.latestJoinCodesByStoreId[createdStoreId] {
                                latestCodeBanner = code
                            }

                            name = ""
                            address = ""
                            lat = ""
                            lng = ""
                            radius = 150
                        }
                    }
                }

                Section("Stores") {
                    if viewModel.stores.isEmpty {
                        Text("No stores yet")
                    } else {
                        ForEach(viewModel.stores) { store in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(store.name)
                                    .font(.headline)
                                Text("\(store.address) • \(store.radiusMeters)m")
                                    .font(.caption)

                                if let last4 = store.joinCodeLast4 {
                                    Text("Current code ending: ••••\(last4)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: DS.Spacing.s) {
                                    Button("Share code") {
                                        guard let code = viewModel.latestJoinCodesByStoreId[store.id] else {
                                            viewModel.errorMessage = "Rotate the code first to share a new code."
                                            return
                                        }
                                        shareText = "Join \(store.name) in StorePass with code: \(code)"
                                        showShareSheet = true
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Rotate code") {
                                        Task {
                                            await viewModel.rotateJoinCode(storeId: store.id)
                                            if let code = viewModel.latestJoinCodesByStoreId[store.id] {
                                                latestCodeBanner = code
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Stores")
            .task { await viewModel.load() }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [shareText])
            }
            .alert("Join code", isPresented: Binding(get: {
                latestCodeBanner != nil
            }, set: { if !$0 { latestCodeBanner = nil } })) {
                Button("Copy") {
                    UIPasteboard.general.string = latestCodeBanner
                }
                Button("Done", role: .cancel) { }
            } message: {
                Text("Share this code with employees: \(latestCodeBanner ?? "")")
            }
            .alert("Store tools", isPresented: Binding(get: {
                viewModel.errorMessage != nil
            }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
