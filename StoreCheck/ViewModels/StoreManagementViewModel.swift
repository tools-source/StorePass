import Foundation

@MainActor
final class StoreManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []

    private let repository: StoreRepositoryProtocol

    init(repository: StoreRepositoryProtocol) {
        self.repository = repository
    }

    func load() async {
        stores = (try? await repository.fetchStores(ids: nil)) ?? []
    }

    func save(store: Store) async {
        try? await repository.upsertStore(store)
        await load()
    }

    func delete(id: String) async {
        try? await repository.deleteStore(id: id)
        await load()
    }
}
