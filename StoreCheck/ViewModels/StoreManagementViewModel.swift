import FirebaseFirestore
import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var latestJoinCodesByStoreId: [String: String] = [:]
    @Published var storeError: String?
    @Published var toastMessage: String?
    @Published var isCreatingStore = false

    private let repository: StoreRepositoryProtocol
    private var toastClearTask: Task<Void, Never>?

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

    func createStore(
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Int
    ) async -> Bool {
        guard !isCreatingStore else { return false }
        isCreatingStore = true
        defer { isCreatingStore = false }

        do {
            let result = try await repository.createStore(
                name: name,
                address: address,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters
            )
            latestJoinCodesByStoreId[result.store.id] = result.joinCode
            showToast("Store created. Code: \(result.joinCode)")
            storeError = nil
            return true
        } catch {
            storeError = error.localizedDescription
            logCreateError(error)
            return false
        }
    }

    func saveStore(_ store: Store) async {
        do {
            try await repository.upsertStore(store)
            showToast("Store updated")
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            print("[Stores] Save error: \(error.localizedDescription)")
        }
    }

    func deleteStore(id: String) async {
        do {
            try await repository.deleteStore(id: id)
            showToast("Store deleted")
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
            showToast("Code rotated")
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

    func presentStoreError(_ message: String) {
        storeError = message
    }

    func clearStoreError() {
        storeError = nil
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.toastMessage = nil
            }
        }
    }

    private func logCreateError(_ error: Error) {
        let nsError = error as NSError
        print("[Stores] Create error: \(error.localizedDescription)")
        print("[Stores] Create NSError domain=\(nsError.domain) code=\(nsError.code)")
        print("[Stores] Create NSError userInfo=\(nsError.userInfo)")

        // ✅ Correct way to decode Firestore error code
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            let firestoreCode = FirestoreErrorCode(code)
            print("[Stores] Create FirestoreErrorCode=\(firestoreCode) (code=\(code))")
        }

        if let path = nsError.userInfo["path"] as? String {
            print("[Stores] Create write path=\(path)")
        }
    }
}
