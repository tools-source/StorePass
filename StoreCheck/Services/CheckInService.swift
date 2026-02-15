import CoreLocation
import Foundation
import UIKit

protocol CheckInServiceProtocol {
    func evaluateLocation(for store: Store) -> LocationCheckState
    func submitCheckIn(user: UserProfile, store: Store) async throws -> CheckIn
}

final class CheckInService: CheckInServiceProtocol {
    private let userRepository: UserRepositoryProtocol
    private let storeRepository: StoreRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol
    private let offlineQueue: OfflineCheckInQueueProtocol
    private let maxAccuracyMeters: Double = 50

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

    func evaluateLocation(for store: Store) -> LocationCheckState {
        let auth = locationService.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else { return .permissionDenied }
        guard locationService.isPreciseLocationEnabled else { return .preciseLocationRequired }
        guard let loc = locationService.currentLocation else { return .locationUnavailable }
        guard loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= maxAccuracyMeters else {
            return .lowAccuracy(loc.horizontalAccuracy)
        }
        let distance = locationService.distance(from: loc.coordinate, to: store.coordinate)
        return distance <= store.radiusMeters ? .inRange(distance: distance) : .outOfRange(distance: distance)
    }

    func submitCheckIn(user: UserProfile, store: Store) async throws -> CheckIn {
        guard let loc = locationService.currentLocation else {
            throw NSError(domain: "StoreCheck", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Location unavailable"])
        }

        let distance = locationService.distance(from: loc.coordinate, to: store.coordinate)
        let inRange = distance <= store.radiusMeters
        let checkIn = CheckIn(
            id: UUID().uuidString,
            employeeId: user.id,
            storeId: store.id,
            storeName: store.name,
            employeeName: user.name,
            checkInTime: Date(),
            clientLat: loc.coordinate.latitude,
            clientLng: loc.coordinate.longitude,
            serverValidated: false,
            distanceMeters: distance,
            accuracyMeters: loc.horizontalAccuracy,
            deviceInfo: DeviceInfo(model: UIDevice.current.model, osVersion: UIDevice.current.systemVersion),
            status: inRange ? .approved : .rejected,
            rejectReason: inRange ? nil : "Out of range"
        )

        do {
            try await checkInRepository.createCheckIn(checkIn)
        } catch {
            try offlineQueue.enqueue(checkIn)
            throw NSError(domain: "StoreCheck", code: 3002, userInfo: [NSLocalizedDescriptionKey: "Offline: check-in queued until network is available"])
        }

        return checkIn
    }
}
