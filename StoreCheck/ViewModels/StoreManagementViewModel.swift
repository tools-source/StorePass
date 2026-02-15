import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var errorMessage: String?

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

    func save(store: Store) async {
        do {
            try await repository.upsertStore(store)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
