import FirebaseFirestore
import FirebaseFirestore
import Foundation

protocol CheckInRepositoryProtocol {
    func createCheckIn(_ checkIn: CheckIn) async throws
    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn]
    func fetchTodaysCheckIns() async throws -> [CheckIn]
}

final class FirestoreCheckInRepository: CheckInRepositoryProtocol {
    private let db = Firestore.firestore()

    func createCheckIn(_ checkIn: CheckIn) async throws {
        try db.collection("checkins").document(checkIn.id).setData(from: checkIn)
    }

    func fetchCheckIns(employeeId: String? = nil, limit: Int = 30) async throws -> [CheckIn] {
        var query: Query = db.collection("checkins").order(by: "checkInTime", descending: true).limit(to: limit)
        if let employeeId {
            query = query.whereField("employeeId", isEqualTo: employeeId)
        }
        let snap = try await query.getDocuments()
        return try snap.documents.map { try $0.data(as: CheckIn.self) }
    }

    func fetchTodaysCheckIns() async throws -> [CheckIn] {
        let start = Calendar.current.startOfDay(for: Date())
        let snap = try await db.collection("checkins")
            .whereField("checkInTime", isGreaterThanOrEqualTo: start)
            .order(by: "checkInTime", descending: true)
            .getDocuments()
        return try snap.documents.map { try $0.data(as: CheckIn.self) }
    }
}
