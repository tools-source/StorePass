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
    @Published var isShowingPhotoPicker = false
    @Published var pendingPhotoPurpose: CheckInPhotoKind?
    @Published var isPhotoCheckInInProgress = false
    @Published var checkInRetryMessage: String?
    @Published var showCheckInRetryAlert = false

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol
    private let imageUploadService: ImageUploadServiceProtocol
    private let photoCompressionQuality: CGFloat = 0.7

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
        refreshLocation()
        guard blockedReason == nil else {
            errorMessage = blockedReason
            return
        }
        pendingPhotoPurpose = CheckInPhotoKind.checkIn
        isShowingPhotoPicker = true
        PhotoVerifyLogger.log("photo picker launch requested purpose=checkIn")
    }

    func beginCheckOutPhotoCapture() {
        refreshLocation()
        guard blockedReason == nil else {
            errorMessage = blockedReason
            return
        }
        pendingPhotoPurpose = CheckInPhotoKind.checkOut
        isShowingPhotoPicker = true
        PhotoVerifyLogger.log("photo picker launch requested purpose=checkOut")
    }

    func didCancelPhotoCapture() {
        PhotoVerifyLogger.log("photo capture canceled; skipping check-in/check-out")
        pendingPhotoPurpose = nil
        isShowingPhotoPicker = false
    }

    func processCapturedPhoto(_ image: UIImage) async {
        guard let purpose = pendingPhotoPurpose else { return }
        switch purpose {
        case CheckInPhotoKind.checkIn:
            await checkIn(with: image)
        case CheckInPhotoKind.checkOut:
            await checkOut(with: image)
        }
        pendingPhotoPurpose = nil
    }

    private func checkIn(with image: UIImage) async {
        guard let user = authService.currentUser else {
            errorMessage = "Sign in required."
            return
        }
        guard let store = selectedStore else {
            errorMessage = "No assigned store available."
            return
        }
        guard blockedReason == nil else {
            errorMessage = blockedReason
            return
        }
        guard let location = locationService.currentLocation else {
            errorMessage = "Location unavailable."
            return
        }

        isPhotoCheckInInProgress = true

        do {
            guard var jpegData = image.jpegData(compressionQuality: photoCompressionQuality) else {
                throw NSError(domain: "StorePass", code: 5201, userInfo: [NSLocalizedDescriptionKey: "Could not process photo."])
            }
            if jpegData.count > 2_000_000, let reduced = image.jpegData(compressionQuality: 0.55) {
                jpegData = reduced
            }
            PhotoVerifyLogger.log("jpeg prepared purpose=checkIn compression=\(photoCompressionQuality) bytes=\(jpegData.count)")

            let now = Date()
            let distance = locationService.distance(from: location.coordinate, to: store.coordinate)
            let approved = distance <= Double(store.radiusMeters)

            let checkIn = CheckIn(
                id: UUID().uuidString,
                employeeId: user.id,
                storeId: store.id,
                checkInTime: now,
                checkOutTime: nil,
                clientLat: location.coordinate.latitude,
                clientLng: location.coordinate.longitude,
                distanceMeters: distance,
                accuracyMeters: location.horizontalAccuracy,
                checkOutLat: nil,
                checkOutLng: nil,
                checkOutDistanceMeters: nil,
                checkOutAccuracyMeters: nil,
                durationSeconds: nil,
                status: approved ? .approved : .rejected,
                rejectReason: approved ? nil : "Out of range",
                employeeName: user.name,
                employeeEmail: user.email,
                storeName: store.name,
                checkInPhotoURL: nil,
                checkOutPhotoURL: nil,
                checkInPhotoPath: nil,
                checkOutPhotoPath: nil,
                checkInPhotoCapturedAt: nil,
                checkOutPhotoCapturedAt: nil,
                checkInPhotoUploadedAt: nil,
                checkOutPhotoUploadedAt: nil,
                photoRequired: true,
                photoVersion: 1
            )
            try await checkInRepository.createCheckIn(checkIn)

            let uploadPath = CheckInPhotoStoragePath.makePath(storeId: store.id, employeeId: user.id, checkinId: checkIn.id, kind: CheckInPhotoKind.checkIn)
            PhotoVerifyLogger.log("upload start purpose=checkIn path=\(uploadPath) bytes=\(jpegData.count)")
            let upload = try await imageUploadService.uploadCheckInPhotoData(
                imageData: jpegData,
                storeId: store.id,
                employeeId: user.id,
                checkinId: checkIn.id,
                kind: CheckInPhotoKind.checkIn
            )
            let uploadedAt = Date()
            let capturedAt = Date()
            PhotoVerifyLogger.log("upload end purpose=checkIn path=\(upload.path) downloadURL=\(upload.downloadURL)")

            try await checkInRepository.attachPhoto(
                checkinId: checkIn.id,
                storeId: store.id,
                employeeId: user.id,
                kind: CheckInPhotoKind.checkIn,
                photoPath: upload.path,
                photoURL: upload.downloadURL,
                capturedAt: capturedAt,
                uploadedAt: uploadedAt
            )

            PhotoVerifyLogger.log("firestore update end purpose=checkIn checkinId=\(checkIn.id)")

            checkInSuccessBanner = true
            isShowingPhotoPicker = false
            try await loadTodaySessions()
        } catch {
            let friendlyError = userFacingPhotoFlowError(error, fallback: "Couldn’t complete photo check-in. Please try again.")
            checkInRetryMessage = friendlyError
            showCheckInRetryAlert = true
        }

        isPhotoCheckInInProgress = false
    }

    func retryPhotoCheckIn() {
        checkInRetryMessage = nil
        showCheckInRetryAlert = false
        if activeSession == nil {
            beginCheckInPhotoCapture()
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
            guard var jpegData = image.jpegData(compressionQuality: photoCompressionQuality) else {
                throw NSError(domain: "StorePass", code: 5201, userInfo: [NSLocalizedDescriptionKey: "Could not process photo."])
            }
            if jpegData.count > 2_000_000, let reduced = image.jpegData(compressionQuality: 0.55) {
                jpegData = reduced
            }
            PhotoVerifyLogger.log("jpeg prepared purpose=checkOut compression=\(photoCompressionQuality) bytes=\(jpegData.count)")

            let uploadPath = CheckInPhotoStoragePath.makePath(storeId: store.id, employeeId: user.id, checkinId: activeSession.id, kind: CheckInPhotoKind.checkOut)
            PhotoVerifyLogger.log("upload start purpose=checkOut path=\(uploadPath) bytes=\(jpegData.count)")
            let upload = try await imageUploadService.uploadCheckInPhotoData(
                imageData: jpegData,
                storeId: store.id,
                employeeId: user.id,
                checkinId: activeSession.id,
                kind: CheckInPhotoKind.checkOut
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
                accuracyMeters: location.horizontalAccuracy
            )
            try await checkInRepository.attachPhoto(
                checkinId: activeSession.id,
                storeId: store.id,
                employeeId: user.id,
                kind: CheckInPhotoKind.checkOut,
                photoPath: upload.path,
                photoURL: upload.downloadURL,
                capturedAt: Date(),
                uploadedAt: uploadedAt
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
