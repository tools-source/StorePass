import Foundation

protocol OfflineCheckInQueueProtocol {
    func enqueue(_ checkIn: CheckIn) throws
    func pending() throws -> [CheckIn]
    func clear() throws
}

final class OfflineCheckInQueue: OfflineCheckInQueueProtocol {
    private let key = "offline_checkins"

    func enqueue(_ checkIn: CheckIn) throws {
        var all = try pending()
        all.append(checkIn)
        let data = try JSONEncoder().encode(all)
        UserDefaults.standard.set(data, forKey: key)
    }

    func pending() throws -> [CheckIn] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([CheckIn].self, from: data)
    }

    func clear() throws {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
