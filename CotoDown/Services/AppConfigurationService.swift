import Foundation

struct CotoDownConfiguration: Codable {
    var version: Int
    var resolverEndpoint: String
    var resolverDelivery: ResolverDelivery
    var resolverToken: String?
    var notificationsEnabled: Bool
    var maxConcurrentDownloads: Int?
    var templates: [DownloadTemplate]
}

enum AppConfigurationError: LocalizedError {
    case unsupportedVersion
    case emptyTemplates

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "This configuration version is not supported."
        case .emptyTemplates:
            "The configuration does not contain any templates."
        }
    }
}

enum AppConfigurationService {
    static func exportURL(for configuration: CotoDownConfiguration) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coto-down-configuration")
            .appendingPathExtension("json")
        try data.write(to: url, options: [.atomic])
        return url
    }

    static func importConfiguration(from url: URL) throws -> CotoDownConfiguration {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(CotoDownConfiguration.self, from: data)
        guard configuration.version == 1 else {
            throw AppConfigurationError.unsupportedVersion
        }
        guard !configuration.templates.isEmpty else {
            throw AppConfigurationError.emptyTemplates
        }

        return configuration
    }
}
