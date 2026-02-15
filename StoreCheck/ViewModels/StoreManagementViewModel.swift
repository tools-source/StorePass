import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var latestJoinCodesByStoreId: [String: String] = [:]
    @Published var storeError: String?
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
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Load error: \(error.localizedDescription)")
        }
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async {
        do {
            let result = try await repository.createStore(name: name, address: address, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
            latestJoinCodesByStoreId[result.store.id] = result.joinCode
            toastMessage = "Store created. Code: \(result.joinCode)"
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Create error: \(error.localizedDescription)")
        }
    }

    func saveStore(_ store: Store) async {
        do {
            try await repository.upsertStore(store)
            toastMessage = "Store updated"
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Save error: \(error.localizedDescription)")
        }
    }

    func deleteStore(id: String) async {
        do {
            try await repository.deleteStore(id: id)
            toastMessage = "Store deleted"
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Delete error: \(error.localizedDescription)")
        }
    }

    func rotateStoreCode(storeId: String) async {
        do {
            let code = try await repository.rotateStoreCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code
            toastMessage = "Code rotated"
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Rotate-code error: \(error.localizedDescription)")
        }
    }

    func fetchJoinCode(storeId: String) async -> String? {
        do {
            let code = try await repository.getStoreJoinCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code
            storeError = nil
            return code
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Fetch-code error: \(error.localizedDescription)")
            return nil
        }
    }
}
