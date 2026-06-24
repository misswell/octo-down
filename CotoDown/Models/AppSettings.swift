import Foundation

struct DownloadTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var mode: MediaMode
    var arguments: String

    init(id: UUID = UUID(), name: String, mode: MediaMode, arguments: String) {
        self.id = id
        self.name = name
        self.mode = mode
        self.arguments = arguments
    }
}

enum ResolverDelivery: String, Codable, CaseIterable, Identifiable {
    case direct
    case hosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direct URL"
        case .hosted: "Hosted File"
        }
    }

    var description: String {
        switch self {
        case .direct:
            "Resolver returns a media URL and coto down downloads it."
        case .hosted:
            "Resolver downloads or converts first, then returns a hosted file."
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var resolverEndpoint: String {
        didSet { save() }
    }

    @Published var resolverDelivery: ResolverDelivery {
        didSet { save() }
    }

    @Published var resolverToken: String {
        didSet { save() }
    }

    @Published var templates: [DownloadTemplate] {
        didSet { save() }
    }

    @Published var notificationsEnabled: Bool {
        didSet { save() }
    }

    @Published var maxConcurrentDownloads: Int {
        didSet {
            maxConcurrentDownloads = Self.clampedMaxConcurrentDownloads(maxConcurrentDownloads)
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private let endpointKey = "resolverEndpoint"
    private let deliveryKey = "resolverDelivery"
    private let tokenKey = "resolverToken"
    private let templatesKey = "downloadTemplates"
    private let notificationsKey = "notificationsEnabled"
    private let maxConcurrentDownloadsKey = "maxConcurrentDownloads"

    init() {
        resolverEndpoint = defaults.string(forKey: endpointKey) ?? ""
        resolverDelivery = ResolverDelivery(rawValue: defaults.string(forKey: deliveryKey) ?? "") ?? .direct
        resolverToken = defaults.string(forKey: tokenKey) ?? ""
        notificationsEnabled = Self.notificationsEnabledPreference
        maxConcurrentDownloads = Self.maxConcurrentDownloadsPreference

        if let data = defaults.data(forKey: templatesKey),
           let decoded = try? JSONDecoder().decode([DownloadTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = Self.defaultTemplates
        }
    }

    func template(named name: String) -> DownloadTemplate {
        templates.first { $0.name == name } ?? Self.defaultTemplates[0]
    }

    func resetTemplates() {
        templates = Self.defaultTemplates
    }

    func exportConfiguration() -> CotoDownConfiguration {
        CotoDownConfiguration(
            version: 1,
            resolverEndpoint: resolverEndpoint,
            resolverDelivery: resolverDelivery,
            resolverToken: resolverToken,
            notificationsEnabled: notificationsEnabled,
            maxConcurrentDownloads: maxConcurrentDownloads,
            templates: templates
        )
    }

    func apply(configuration: CotoDownConfiguration) {
        resolverEndpoint = configuration.resolverEndpoint
        resolverDelivery = configuration.resolverDelivery
        resolverToken = configuration.resolverToken ?? ""
        notificationsEnabled = configuration.notificationsEnabled
        maxConcurrentDownloads = Self.clampedMaxConcurrentDownloads(
            configuration.maxConcurrentDownloads ?? Self.defaultMaxConcurrentDownloads
        )
        templates = configuration.templates
    }

    private func save() {
        defaults.set(resolverEndpoint, forKey: endpointKey)
        defaults.set(resolverDelivery.rawValue, forKey: deliveryKey)
        defaults.set(resolverToken, forKey: tokenKey)
        defaults.set(notificationsEnabled, forKey: notificationsKey)
        defaults.set(maxConcurrentDownloads, forKey: maxConcurrentDownloadsKey)
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: templatesKey)
        }
    }

    nonisolated static var notificationsEnabledPreference: Bool {
        UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    nonisolated static var maxConcurrentDownloadsPreference: Int {
        let savedValue = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        return clampedMaxConcurrentDownloads(savedValue == 0 ? defaultMaxConcurrentDownloads : savedValue)
    }

    nonisolated static let defaultMaxConcurrentDownloads = 3
    nonisolated static let maxConcurrentDownloadsRange = 1...6

    nonisolated static func clampedMaxConcurrentDownloads(_ value: Int) -> Int {
        min(max(value, maxConcurrentDownloadsRange.lowerBound), maxConcurrentDownloadsRange.upperBound)
    }

    static let defaultTemplates: [DownloadTemplate] = [
        DownloadTemplate(
            name: "Video",
            mode: .video,
            arguments: "-f bv*+ba/b --embed-thumbnail --embed-metadata"
        ),
        DownloadTemplate(
            name: "Subtitled Video",
            mode: .video,
            arguments: "-f bv*+ba/b --write-subs --write-auto-subs --sub-langs all,-live_chat --embed-subs --merge-output-format mp4 --embed-thumbnail --embed-metadata"
        ),
        DownloadTemplate(
            name: "Audio",
            mode: .audio,
            arguments: "-x --audio-format m4a --embed-thumbnail --embed-metadata"
        ),
        DownloadTemplate(
            name: "Playlist",
            mode: .playlist,
            arguments: "--yes-playlist -f bv*+ba/b"
        ),
        DownloadTemplate(
            name: "Custom",
            mode: .custom,
            arguments: ""
        )
    ]
}
