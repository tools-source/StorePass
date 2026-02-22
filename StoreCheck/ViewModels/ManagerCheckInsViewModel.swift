import Foundation

@MainActor
final class ManagerCheckInsViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var selectedStoreId: String?
    @Published var checkIns: [CheckIn] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let storeRepository: StoreRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(
        storeRepository: StoreRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        authRepository: AuthRepositoryProtocol
    ) {
        self.storeRepository = storeRepository
        self.checkInRepository = checkInRepository
        self.authRepository = authRepository
    }

    func load() async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let managerStores = try await storeRepository.fetchManagerStores(managerId: managerId)
            stores = managerStores

            if selectedStoreId == nil || !managerStores.contains(where: { $0.id == selectedStoreId }) {
                selectedStoreId = managerStores.first?.id
            }

            guard let storeId = selectedStoreId else {
                checkIns = []
                errorMessage = nil
                return
            }

            checkIns = try await checkInRepository.fetchManagerStoreCheckIns(managerId: managerId, storeId: storeId, limit: 100)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
