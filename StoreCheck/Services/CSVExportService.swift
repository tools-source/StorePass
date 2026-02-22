import Foundation

protocol CSVExportServiceProtocol {
    func generateCSV(from checkIns: [CheckIn], filePrefix: String) -> URL?
    func generateCSVText(from checkIns: [CheckIn]) -> String
}

final class CSVExportService: CSVExportServiceProtocol {
    func generateCSV(from checkIns: [CheckIn], filePrefix: String) -> URL? {
        let csv = generateCSVText(from: checkIns)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let safePrefix = filePrefix.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safePrefix)_\(date).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            print("[Export][CSV] rows=\(max(checkIns.count, 0)) bytes=\(csv.utf8.count)")
            return url
        } catch {
            return nil
        }
    }

    func generateCSVText(from checkIns: [CheckIn]) -> String {
        var lines = ["employeeName,employeeId,storeName,storeId,checkInTime,checkOutTime,durationMinutes,status,distanceMeters,accuracyMeters"]
        let iso = ISO8601DateFormatter()

        for item in checkIns {
            let durationMinutes = (item.computedDurationSeconds ?? 0) / 60
            lines.append([
                escape(item.employeeName),
                escape(item.employeeId),
                escape(item.storeName),
                escape(item.storeId),
                escape(iso.string(from: item.checkInTime)),
                escape(item.checkOutTime.map { iso.string(from: $0) } ?? ""),
                escape("\(durationMinutes)"),
                escape(item.status.rawValue),
                escape("\(Int(item.distanceMeters))"),
                escape("\(Int(item.accuracyMeters))")
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
