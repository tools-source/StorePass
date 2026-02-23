import Foundation

struct StoreCreationResult {
    let store: Store
    let joinCode: String
}

struct JoinStoreResult {
    let storeId: String
    let storeName: String
    let alreadyJoined: Bool
    let assignedStoreIds: [String]
}

protocol StoreRepositoryProtocol {
    func fetchStores(ids: [String]?) async throws -> [Store]
    func fetchManagerStores(managerId: String) async throws -> [Store]
    func upsertStore(_ store: Store) async throws
    func deleteStore(id: String) async throws
    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult
    func rotateStoreCode(storeId: String) async throws -> String
    func getStoreJoinCode(storeId: String) async throws -> String
    func joinStoreByCode(code: String) async throws -> JoinStoreResult
    func leaveStore(storeId: String) async throws
}
