import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var latestJoinCodesByStoreId: [String: String] = [:]
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    private let repository: StoreRepositoryProtocol

    init(repository: StoreRepositoryProtocol) {
        self.repository = repository
    }

    func load(managerId: String?) async {
        do {
            if let managerId {
                stores = try await repository.fetchManagerStores(managerId: managerId)
            } else {
                stores = try await repository.fetchStores(ids: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async {
        do {
            let result = try await repository.createStore(name: name, address: address, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
            latestJoinCodesByStoreId[result.store.id] = result.joinCode
            toastMessage = "Store created. Code: \(result.joinCode)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveStore(_ store: Store) async {
        do {
            try await repository.upsertStore(store)
            toastMessage = "Store updated"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteStore(id: String) async {
        do {
            try await repository.deleteStore(id: id)
            toastMessage = "Store deleted"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rotateStoreCode(storeId: String) async {
        do {
            let code = try await repository.rotateStoreCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code
            toastMessage = "Code rotated"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchJoinCode(storeId: String) async -> String? {
        do {
            let code = try await repository.getStoreJoinCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code
            return code
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
