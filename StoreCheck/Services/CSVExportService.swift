import Foundation

protocol CSVExportServiceProtocol {
    func generateCSV(from checkIns: [CheckIn], filePrefix: String) -> URL?
    func generateCSVText(from checkIns: [CheckIn]) -> String
    func generatePayrollCSV(from checkIns: [CheckIn], employeeSummariesById: [String: EmployeeSummary], filePrefix: String) -> URL?
    func generatePayrollCSVText(from checkIns: [CheckIn], employeeSummariesById: [String: EmployeeSummary]) -> String
}

final class CSVExportService: CSVExportServiceProtocol {
    func generateCSV(from checkIns: [CheckIn], filePrefix: String) -> URL? {
        let csv = generateCSVText(from: checkIns)
        return writeCSV(csv, filePrefix: filePrefix)
    }

    func generatePayrollCSV(from checkIns: [CheckIn], employeeSummariesById: [String: EmployeeSummary], filePrefix: String) -> URL? {
        let csv = generatePayrollCSVText(from: checkIns, employeeSummariesById: employeeSummariesById)
        return writeCSV(csv, filePrefix: filePrefix)
    }

    private func writeCSV(_ csv: String, filePrefix: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        let safePrefix = filePrefix.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safePrefix)_\(date).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            let rowCount = max(csv.split(separator: "\n", omittingEmptySubsequences: false).count - 1, 0)
            print("[Export][CSV] rows=\(rowCount) bytes=\(csv.utf8.count)")
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

    func generatePayrollCSVText(from checkIns: [CheckIn], employeeSummariesById: [String: EmployeeSummary]) -> String {
        var lines = ["employeeName,date,checkIn,checkOut,totalHours,pay,storeName,status"]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        for item in checkIns.sorted(by: { $0.checkInTime < $1.checkInTime }) {
            let workedSeconds = max(item.computedDurationSeconds ?? 0, 0)
            let totalHours = Double(workedSeconds) / 3600
            let hourlyRateCents = employeeSummariesById[item.employeeId]?.hourlyRateCents
            let pay: String
            if let hourlyRateCents, workedSeconds > 0 {
                let gross = totalHours * (Double(hourlyRateCents) / 100)
                pay = String(format: "%.2f", gross)
            } else {
                pay = ""
            }

            lines.append([
                escape(item.employeeName),
                escape(dateFormatter.string(from: item.checkInTime)),
                escape(timeFormatter.string(from: item.checkInTime)),
                escape(item.checkOutTime.map { timeFormatter.string(from: $0) } ?? ""),
                escape(String(format: "%.2f", totalHours)),
                escape(pay),
                escape(item.storeName),
                escape(item.status.rawValue)
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
