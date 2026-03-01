import FirebaseStorage
import Foundation
import UIKit

@MainActor
final class EmployeeDashboardViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var selectedStore: Store?
    @Published var locationStatus: LocationCheckState = .unknown
    @Published var errorMessage: String?
    @Published var checkInSuccessBanner = false
    @Published var joinCodeInput = ""
    @Published var joinStatusMessage: String?
    @Published var todaysCheckIns: [CheckIn] = []
    @Published var lastLocationRefreshAt: Date?
    @Published var isShowingCamera = false
    @Published var pendingPhotoPurpose: CheckInPhotoKind?

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol
    private let imageUploadService: ImageUploadServiceProtocol
    private let photoCompressionQuality: CGFloat = 0.75

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol,
        imageUploadService: ImageUploadServiceProtocol
    ) {
        self.authService = authService
        self.storeRepository = storeRepository
        self.checkInService = checkInService
        self.checkInRepository = checkInRepository
        self.locationService = locationService
        self.imageUploadService = imageUploadService
    }

    var blockedReason: String? {
        checkInService.blockedReason(for: locationStatus, user: authService.currentUser, store: selectedStore)
    }

    var activeSession: CheckIn? {
        todaysCheckIns.first(where: { $0.checkOutTime == nil })
    }

    func selectStore(withId storeId: String) {
        Task { @MainActor in
            selectedStore = stores.first(where: { $0.id == storeId })
            refreshLocation()
        }
    }

    func load() async {
        guard let user = authService.currentUser else { return }
        do {
            stores = try await storeRepository.fetchStores(ids: user.assignedStoreIds)
            if let currentSelection = selectedStore, stores.contains(where: { $0.id == currentSelection.id }) {
                selectedStore = currentSelection
            } else {
                selectedStore = stores.first
            }
            refreshLocation()
            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocation() {
        guard let selectedStore else { return }
        lastLocationRefreshAt = Date()
        locationService.requestWhenInUseAuthorization()
        locationService.requestLocation()
        locationStatus = checkInService.evaluateLocation(for: selectedStore, user: authService.currentUser)
        if let locationError = locationService.lastErrorMessage {
            errorMessage = locationError
        }
    }

    func beginCheckInPhotoCapture() {
        pendingPhotoPurpose = .checkIn
        isShowingCamera = true
        PhotoVerifyLogger.log("camera launch requested purpose=checkIn")
    }

    func beginCheckOutPhotoCapture() {
        pendingPhotoPurpose = .checkOut
        isShowingCamera = true
        PhotoVerifyLogger.log("camera launch requested purpose=checkOut")
    }

    func didCancelPhotoCapture() {
        PhotoVerifyLogger.log("photo capture canceled; skipping check-in/check-out")
        pendingPhotoPurpose = nil
        isShowingCamera = false
    }

    func processCapturedPhoto(_ image: UIImage) async {
        guard let purpose = pendingPhotoPurpose else { return }
        switch purpose {
        case .checkIn:
            await checkIn(with: image)
        case .checkOut:
            await checkOut(with: image)
        }
        pendingPhotoPurpose = nil
    }

    private func checkIn(with image: UIImage) async {
        guard let user = authService.currentUser, let store = selectedStore else { return }
        let checkinId = UUID().uuidString
        let capturedAt = Date()

        do {
            guard let jpegData = image.jpegData(compressionQuality: photoCompressionQuality) else {
                throw NSError(domain: "StorePass", code: 5201, userInfo: [NSLocalizedDescriptionKey: "Could not process photo."])
            }
            PhotoVerifyLogger.log("jpeg prepared purpose=checkIn compression=\(photoCompressionQuality) bytes=\(jpegData.count)")

            let uploadPath = CheckInPhotoStoragePath.makePath(storeId: store.id, employeeId: user.id, checkinId: checkinId, kind: .checkIn)
            PhotoVerifyLogger.log("upload start purpose=checkIn path=\(uploadPath)")
            let upload = try await imageUploadService.uploadCheckInPhotoData(
                imageData: jpegData,
                storeId: store.id,
                employeeId: user.id,
                checkinId: checkinId,
                kind: .checkIn
            )
            let uploadedAt = Date()
            PhotoVerifyLogger.log("upload end purpose=checkIn path=\(upload.path) downloadURL=\(upload.downloadURL)")

            PhotoVerifyLogger.log("firestore update start purpose=checkIn checkinId=\(checkinId)")
            _ = try await checkInService.submitCheckIn(
                user: user,
                store: store,
                checkinId: checkinId,
                checkInPhotoPath: upload.path,
                checkInPhotoURL: upload.downloadURL,
                checkInPhotoCapturedAt: capturedAt,
                checkInPhotoUploadedAt: uploadedAt
            )
            PhotoVerifyLogger.log("firestore update end purpose=checkIn checkinId=\(checkinId)")

            checkInSuccessBanner = true
            try await loadTodaySessions()
        } catch {
            errorMessage = userFacingPhotoFlowError(error, fallback: "Couldn’t upload photo. Please try again.")
        }
    }

    private func checkOut(with image: UIImage) async {
        guard let activeSession, let store = selectedStore else { return }
        guard let user = authService.currentUser else { return }
        guard let location = locationService.currentLocation else {
            errorMessage = "Location unavailable."
            return
        }

        do {
            guard let jpegData = image.jpegData(compressionQuality: photoCompressionQuality) else {
                throw NSError(domain: "StorePass", code: 5201, userInfo: [NSLocalizedDescriptionKey: "Could not process photo."])
            }
            PhotoVerifyLogger.log("jpeg prepared purpose=checkOut compression=\(photoCompressionQuality) bytes=\(jpegData.count)")

            let uploadPath = CheckInPhotoStoragePath.makePath(storeId: store.id, employeeId: user.id, checkinId: activeSession.id, kind: .checkOut)
            PhotoVerifyLogger.log("upload start purpose=checkOut path=\(uploadPath)")
            let upload = try await imageUploadService.uploadCheckInPhotoData(
                imageData: jpegData,
                storeId: store.id,
                employeeId: user.id,
                checkinId: activeSession.id,
                kind: .checkOut
            )
            let uploadedAt = Date()
            PhotoVerifyLogger.log("upload end purpose=checkOut path=\(upload.path) downloadURL=\(upload.downloadURL)")

            let distance = locationService.distance(from: location.coordinate, to: store.coordinate)
            PhotoVerifyLogger.log("firestore update start purpose=checkOut checkinId=\(activeSession.id)")
            try await checkInRepository.checkout(
                checkinId: activeSession.id,
                storeId: store.id,
                managerId: nil,
                checkoutLat: location.coordinate.latitude,
                checkoutLng: location.coordinate.longitude,
                distanceMeters: distance,
                accuracyMeters: location.horizontalAccuracy,
                checkOutPhotoPath: upload.path,
                checkOutPhotoURL: upload.downloadURL,
                checkOutPhotoCapturedAt: Date(),
                checkOutPhotoUploadedAt: uploadedAt
            )
            PhotoVerifyLogger.log("firestore update end purpose=checkOut checkinId=\(activeSession.id)")
            try await loadTodaySessions()
        } catch {
            errorMessage = userFacingPhotoFlowError(error, fallback: "Couldn’t upload photo. Please try again.")
        }
    }

    private func loadTodaySessions() async throws {
        guard let user = authService.currentUser else { return }
        let history = try await checkInRepository.fetchEmployeeCheckIns(employeeId: user.id, limit: 30)
        let today = Calendar.current.startOfDay(for: Date())
        todaysCheckIns = history.filter { Calendar.current.isDate($0.checkInTime, inSameDayAs: today) }
    }

    func joinStoreByCode() async {
        do {
            errorMessage = nil
            let result = try await storeRepository.joinStoreByCode(code: joinCodeInput)

            if var currentUser = authService.currentUser {
                currentUser.assignedStoreIds = result.assignedStoreIds
                authService.setCurrentUser(currentUser)
            }

            let joinedStore = try await storeRepository.fetchStores(ids: [result.storeId]).first
            if let joinedStore, stores.contains(where: { $0.id == joinedStore.id }) == false {
                stores.append(joinedStore)
                stores.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            selectedStore = selectedStore ?? joinedStore
            refreshLocation()
            joinStatusMessage = result.alreadyJoined
                ? "You're already linked to \(result.storeName)."
                : "Joined \(result.storeName) successfully."
            joinCodeInput = ""
        } catch {
            joinStatusMessage = nil
            errorMessage = error.localizedDescription
            print("[Stores] Join-by-code error: \(error.localizedDescription)")
        }
    }

    private func userFacingPhotoFlowError(_ error: Error, fallback: String) -> String? {
        let nsError = error as NSError

        if nsError.domain == StorageErrorDomain,
           nsError.code == StorageErrorCode.objectNotFound.rawValue {
            return nil
        }

        if nsError.domain == StorageErrorDomain {
            return fallback
        }

        return error.localizedDescription
    }

    func leaveStore(storeId: String) async {
        do {
            try await storeRepository.leaveStore(storeId: storeId)
            if var currentUser = authService.currentUser {
                currentUser.assignedStoreIds.removeAll { $0 == storeId }
                authService.setCurrentUser(currentUser)
            }
            await load()
            if stores.isEmpty {
                selectedStore = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
