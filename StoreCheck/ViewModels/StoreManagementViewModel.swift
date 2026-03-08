import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var latestJoinCodesByStoreId: [String: String] = [:]
    @Published var broadcastMessagesByStoreId: [String: [BroadcastMessage]] = [:]
    @Published var storeError: String?
    @Published var toastMessage: String?
    @Published var isCreatingStore = false
    @Published var isUpdatingStoreSettings = false
    @Published var isSendingBroadcast = false

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
            AppLog.error("Failed loading stores", error: error)
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
            upsertLocalStore(result.store)
            latestJoinCodesByStoreId[result.store.id] = result.joinCode
            showToast("Store created. Join code: \(result.joinCode)")
            storeError = nil
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
            return true
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed creating store", error: error)
            return false
        }
    }

    func saveStore(_ store: Store) async {
        do {
            try await repository.upsertStore(store)
            upsertLocalStore(store)
            showToast("Store updated")
            storeError = nil
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed saving store", error: error)
        }
    }

    func deleteStore(id: String) async {
        do {
            try await repository.deleteStore(id: id)
            stores.removeAll { $0.id == id }
            latestJoinCodesByStoreId[id] = nil
            showToast("Store deleted")
            storeError = nil
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed deleting store", error: error)
        }
    }

    func rotateStoreCode(storeId: String, managerId: String?) async {
        _ = managerId

        do {
            let code = try await repository.rotateStoreCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code

            if let index = stores.firstIndex(where: { $0.id == storeId }) {
                stores[index].joinCode = code
                stores[index].joinCodeCiphertext = code
                stores[index].joinCodeLast4 = String(code.suffix(4))
                stores[index].updatedAt = Date()
            }

            showToast("Join code rotated")
            storeError = nil
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed rotating store code", error: error)
        }
    }

    func resolvedJoinCode(for store: Store) -> String {
        if let cached = latestJoinCodesByStoreId[store.id], !cached.isEmpty {
            return cached
        }
        return store.resolvedJoinCode ?? "----"
    }

    func resolvedJoinCode(storeId: String) -> String {
        if let cached = latestJoinCodesByStoreId[storeId], !cached.isEmpty {
            return cached
        }
        if let store = stores.first(where: { $0.id == storeId }) {
            return store.resolvedJoinCode ?? "----"
        }
        return "----"
    }

    func fetchJoinCode(storeId: String) async -> String? {
        do {
            let code = try await repository.getStoreJoinCode(storeId: storeId)
            latestJoinCodesByStoreId[storeId] = code
            if let index = stores.firstIndex(where: { $0.id == storeId }) {
                stores[index].joinCode = code
                stores[index].joinCodeCiphertext = code
                stores[index].joinCodeLast4 = String(code.suffix(4))
            }
            storeError = nil
            return code
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed fetching join code", error: error)
            return nil
        }
    }

    func presentStoreError(_ message: String) {
        storeError = message
    }

    func clearStoreError() {
        storeError = nil
    }

    func setQRCodeMode(storeId: String, isEnabled: Bool) async {
        guard !isUpdatingStoreSettings else { return }
        isUpdatingStoreSettings = true
        defer { isUpdatingStoreSettings = false }

        do {
            let updatedStore = try await repository.setStoreQRCheckInMode(storeId: storeId, isEnabled: isEnabled)
            upsertLocalStore(updatedStore)
            storeError = nil
            showToast(isEnabled ? "QR check-in enabled" : "QR check-in disabled")
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed toggling QR mode", error: error)
        }
    }

    func rotateQRCode(storeId: String) async -> String? {
        guard !isUpdatingStoreSettings else { return nil }
        isUpdatingStoreSettings = true
        defer { isUpdatingStoreSettings = false }

        do {
            let token = try await repository.rotateStoreQRCode(storeId: storeId)
            if let index = stores.firstIndex(where: { $0.id == storeId }) {
                stores[index].qrCodeToken = token
                stores[index].qrCheckInEnabled = true
                stores[index].updatedAt = Date()
            }
            showToast("Store QR rotated")
            storeError = nil
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
            return token
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed rotating store QR", error: error)
            return nil
        }
    }

    func sendBroadcast(storeId: String, message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            storeError = "Broadcast message cannot be empty."
            return false
        }
        guard trimmed.count <= 500 else {
            storeError = "Broadcast message is too long."
            return false
        }
        guard !isSendingBroadcast else { return false }

        isSendingBroadcast = true
        defer { isSendingBroadcast = false }

        do {
            try await repository.sendBroadcastMessage(storeId: storeId, message: trimmed)
            await loadBroadcastMessages(storeId: storeId)
            storeError = nil
            showToast("Broadcast sent")
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
            return true
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed sending broadcast", error: error)
            return false
        }
    }

    func loadBroadcastMessages(storeId: String) async {
        do {
            let messages = try await repository.fetchBroadcastMessages(storeId: storeId, limit: 50)
            broadcastMessagesByStoreId[storeId] = messages
            storeError = nil
        } catch {
            storeError = error.localizedDescription
            AppLog.error("Failed loading broadcast messages", error: error)
        }
    }

    func broadcastMessages(for storeId: String) -> [BroadcastMessage] {
        broadcastMessagesByStoreId[storeId] ?? []
    }

    private func upsertLocalStore(_ store: Store) {
        if let index = stores.firstIndex(where: { $0.id == store.id }) {
            stores[index] = store
        } else {
            stores.append(store)
        }
        stores.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.toastMessage = nil
            }
        }
    }
}
