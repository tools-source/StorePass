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
    private var isDashboardVisible = false
    private var isManager = false

    init(checkInRepository: CheckInRepositoryProtocol) {
        self.checkInRepository = checkInRepository
    }

    func updateListenerState(isDashboardVisible: Bool, isManager: Bool, source: String) {
        self.isDashboardVisible = isDashboardVisible
        self.isManager = isManager

        #if DEBUG
        print("[Checkins] updateListenerState source=\(source) visible=\(isDashboardVisible) isManager=\(isManager)")
        #endif

        if isDashboardVisible, isManager {
            checkinError = nil
            startListeningIfNeeded(source: source)
        } else {
            stopListening(source: source)
            checkinError = nil
        }
    }

    func refreshListener(source: String) {
        guard isDashboardVisible, isManager else { return }
        stopListening(source: source)
        startListeningIfNeeded(source: source)
    }

    func stopListening(source: String) {
        guard listenerToken != nil else { return }
        #if DEBUG
        print("[Checkins] listener stop source=\(source)")
        #endif
        listenerToken?.cancel()
        listenerToken = nil
    }

    private func startListeningIfNeeded(source: String) {
        guard isDashboardVisible, isManager, listenerToken == nil else { return }

        let filter = CheckInFilter(
            storeId: selectedStoreId.isEmpty ? nil : selectedStoreId,
            status: selectedStatus,
            date: selectedDate
        )

        #if DEBUG
        print("[Checkins] listener start source=\(source) storeId=\(filter.storeId ?? "all") status=\(filter.status?.rawValue ?? "all")")
        #endif

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
                    #if DEBUG
                    print("[Checkins] listener error: \(error.localizedDescription)")
                    #endif
                }
            }
        )
    }
}
