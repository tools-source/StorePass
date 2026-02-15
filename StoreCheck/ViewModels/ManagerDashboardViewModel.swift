import Foundation

@MainActor
final class ManagerDashboardViewModel: ObservableObject {
    @Published var checkIns: [CheckIn] = []
    @Published var selectedStoreId: String = ""
    @Published var selectedStatus: CheckInStatus?
    @Published var selectedDate: Date = Date()
    @Published var checkinError: String?

    private let checkInRepository: CheckInRepositoryProtocol
    private var listenerToken: CheckInListenerToken?

    init(checkInRepository: CheckInRepositoryProtocol) {
        self.checkInRepository = checkInRepository
    }

    func startListening() {
        guard listenerToken == nil else { return }

        let filter = CheckInFilter(
            storeId: selectedStoreId.isEmpty ? nil : selectedStoreId,
            status: selectedStatus,
            date: selectedDate
        )

        listenerToken = checkInRepository.listenToTodaysCheckIns(
            filter: filter,
            onUpdate: { [weak self] checkIns in
                Task { @MainActor in
                    self?.checkIns = checkIns
                    self?.checkinError = nil
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.checkinError = error.localizedDescription
                    print("[Checkins] Listener error: \(error.localizedDescription)")
                }
            }
        )
    }

    func refreshListener() {
        stopListening()
        startListening()
    }

    func stopListening() {
        listenerToken?.cancel()
        listenerToken = nil
    }
}
