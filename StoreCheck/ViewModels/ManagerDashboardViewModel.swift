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
    private var isDashboardActive = false

    init(checkInRepository: CheckInRepositoryProtocol) {
        self.checkInRepository = checkInRepository
    }

    func setDashboardActive(_ isActive: Bool) {
        guard isDashboardActive != isActive else { return }
        isDashboardActive = isActive

        if isActive {
            startListeningIfNeeded()
        } else {
            stopListening()
        }
    }

    func refreshListener() {
        guard isDashboardActive else { return }
        stopListening()
        startListeningIfNeeded()
    }

    func stopListening() {
        listenerToken?.cancel()
        listenerToken = nil
    }

    private func startListeningIfNeeded() {
        guard isDashboardActive, listenerToken == nil else { return }

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
}
