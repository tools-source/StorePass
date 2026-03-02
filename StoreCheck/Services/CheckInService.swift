import CoreLocation
import Foundation

protocol CheckInServiceProtocol {
    func evaluateLocation(for store: Store, user: UserProfile?) -> LocationCheckState
    func blockedReason(for state: LocationCheckState, user: UserProfile?, store: Store?) -> String?
    func submitCheckIn(
        user: UserProfile,
        store: Store,
        checkinId: String
    ) async throws -> CheckIn
}

final class CheckInService: CheckInServiceProtocol {
    private let userRepository: UserRepositoryProtocol
    private let storeRepository: StoreRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol
    private let offlineQueue: OfflineCheckInQueueProtocol
    private let maxAccuracyMeters: Double = 100

    init(
        userRepository: UserRepositoryProtocol,
        storeRepository: StoreRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol,
        offlineQueue: OfflineCheckInQueueProtocol
    ) {
        self.userRepository = userRepository
        self.storeRepository = storeRepository
        self.checkInRepository = checkInRepository
        self.locationService = locationService
        self.offlineQueue = offlineQueue
    }

    func evaluateLocation(for store: Store, user: UserProfile?) -> LocationCheckState {
        guard let user else { return .unknown }
        guard user.isActive else { return .permissionDenied }
        guard !user.assignedStoreIds.isEmpty else { return .locationUnavailable }

        let auth = locationService.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else { return .permissionDenied }
        guard locationService.isPreciseLocationEnabled else { return .preciseLocationRequired }
        guard let location = locationService.currentLocation else { return .locationUnavailable }
        guard location.horizontalAccuracy > 0 && location.horizontalAccuracy <= maxAccuracyMeters else {
            return .lowAccuracy(location.horizontalAccuracy)
        }

        let distance = locationService.distance(from: location.coordinate, to: store.coordinate)
        return distance <= Double(store.radiusMeters) ? .inRange(distance: distance) : .outOfRange(distance: distance)
    }

    func blockedReason(for state: LocationCheckState, user: UserProfile?, store: Store?) -> String? {
        guard let user else { return "Sign in required." }
        guard user.isActive else { return "Your account is disabled. Contact your manager." }
        guard let store else { return "No assigned store available." }
        switch state {
        case .inRange:
            return nil
        case .outOfRange:
            return "You must be inside \(store.radiusMeters)m of \(store.name)."
        case .permissionDenied:
            return "Enable Location permission in Settings."
        case .locationUnavailable:
            return "Location unavailable. Move outdoors and refresh."
        case .preciseLocationRequired:
            return "Turn on Precise Location in iOS Settings."
        case .lowAccuracy(let accuracy):
            return "Current GPS accuracy is ±\(Int(accuracy))m; need ≤100m."
        case .unknown:
            return "Getting your position..."
        }
    }

    func submitCheckIn(
        user: UserProfile,
        store: Store,
        checkinId: String
    ) async throws -> CheckIn {
        guard let location = locationService.currentLocation else {
            throw NSError(domain: "StorePass", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Location unavailable."])
        }

        let distance = locationService.distance(from: location.coordinate, to: store.coordinate)
        let approved = distance <= Double(store.radiusMeters)
        let checkIn = CheckIn(
            id: checkinId,
            employeeId: user.id,
            storeId: store.id,
            checkInTime: Date(),
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
            verifyVersion: nil,
            verifyMethod: nil,
            verifyInInside: nil,
            verifyInDistance1Meters: nil,
            verifyInDistance2Meters: nil,
            verifyInDriftMeters: nil,
            verifyInRead1At: nil,
            verifyInRead2At: nil,
            verifyInAccuracy1Meters: nil,
            verifyInAccuracy2Meters: nil,
            verifyOutInside: nil,
            verifyOutDistance1Meters: nil,
            verifyOutDistance2Meters: nil,
            verifyOutDriftMeters: nil,
            verifyOutRead1At: nil,
            verifyOutRead2At: nil,
            verifyOutAccuracy1Meters: nil,
            verifyOutAccuracy2Meters: nil
        )

        do {
            try await checkInRepository.createCheckIn(checkIn)
            return checkIn
        } catch {
            try offlineQueue.enqueue(checkIn)
            throw NSError(domain: "StorePass", code: 3002, userInfo: [NSLocalizedDescriptionKey: "No network. Check-in queued and will sync later."])
        }
    }
}
