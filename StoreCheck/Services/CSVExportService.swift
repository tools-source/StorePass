import Foundation

protocol CSVExportServiceProtocol {
    func generateCSV(from checkIns: [CheckIn]) -> URL?
}

final class CSVExportService: CSVExportServiceProtocol {
    func generateCSV(from checkIns: [CheckIn]) -> URL? {
        var lines = ["employeeName,storeName,status,distanceMeters,accuracyMeters,checkInTime"]
        let iso = ISO8601DateFormatter()
        for item in checkIns {
            lines.append("\(item.employeeName),\(item.storeName),\(item.status.rawValue),\(Int(item.distanceMeters)),\(Int(item.accuracyMeters)),\(iso.string(from: item.checkInTime))")
        }
        let csv = lines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("storecheck_export_\(UUID().uuidString).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
