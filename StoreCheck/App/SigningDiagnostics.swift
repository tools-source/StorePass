import Foundation

struct SigningDiagnosticsSnapshot {
    let applicationIdentifier: String?
    let teamIdentifier: String?
    let iCloudContainerIdentifiers: [String]
}

enum SigningDiagnostics {
    static func snapshot() -> SigningDiagnosticsSnapshot {
        guard let profile = parsedEmbeddedProvisioningProfile(),
              let entitlements = profile["Entitlements"] as? [String: Any] else {
            return SigningDiagnosticsSnapshot(
                applicationIdentifier: nil,
                teamIdentifier: nil,
                iCloudContainerIdentifiers: []
            )
        }

        let applicationIdentifier = entitlements["application-identifier"] as? String
        let teamIdentifier = entitlements["com.apple.developer.team-identifier"] as? String
        let iCloudContainers = normalizeStringArray(
            entitlements["com.apple.developer.icloud-container-identifiers"]
        )

        return SigningDiagnosticsSnapshot(
            applicationIdentifier: applicationIdentifier,
            teamIdentifier: teamIdentifier,
            iCloudContainerIdentifiers: iCloudContainers
        )
    }

    private static func parsedEmbeddedProvisioningProfile() -> [String: Any]? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .isoLatin1),
              let plistStart = content.range(of: "<plist"),
              let plistEnd = content.range(of: "</plist>") else {
            return nil
        }

        let plistXML = String(content[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistXML.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    private static func normalizeStringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let string = value as? String {
            return [string]
        }
        return []
    }
}
