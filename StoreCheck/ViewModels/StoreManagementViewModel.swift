import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var latestJoinCodesByStoreId: [String: String] = [:]
    @Published var errorMessage: String?
    @Published var lastCreatedStoreId: String?

    private let repository: StoreRepositoryProtocol

    init(repository: StoreRepositoryProtocol) {
        self.repository = repository
    }

    func load() async {
        do {
            stores = try await repository.fetchStores(ids: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createStore(name: String, address: String, lat: Double, lng: Double, radiusMeters: Int) async {
        do {
            let result = try await repository.createStore(name: name, address: address, lat: lat, lng: lng, radiusMeters: radiusMeters)
            latestJoinCodesByStoreId[result.store.id] = result.joinCode
            lastCreatedStoreId = result.store.id
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rotateJoinCode(storeId: String) async {
        do {
            let code = try await repository.rotateJoinCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
