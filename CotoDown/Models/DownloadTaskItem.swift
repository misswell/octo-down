import Foundation

enum DownloadStatus: String, Codable, CaseIterable {
    case queued
    case resolving
    case downloading
    case paused
    case finished
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: "Queued"
        case .resolving: "Resolving"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .finished: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

enum MediaMode: String, Codable, CaseIterable, Identifiable {
    case video
    case audio
    case playlist
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .playlist: "Playlist"
        case .custom: "Custom"
        }
    }
}

struct DownloadTaskItem: Identifiable, Codable, Equatable {
    var id: UUID
    var sourceURL: String
    var resolvedURL: String?
    var resolvedAudioURL: String?
    var title: String
    var fileName: String?
    var mode: MediaMode
    var templateName: String
    var templateArguments: String?
    var argumentOverride: String?
    var resolverEndpoint: String?
    var resolverDelivery: ResolverDelivery?
    var resolverToken: String?
    var status: DownloadStatus
    var progress: Double
    var receivedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double
    var estimatedRemainingSeconds: TimeInterval?
    var lastProgressAt: Date?
    var resumeData: Data?
    var createdAt: Date
    var finishedAt: Date?
    var localPath: String?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case resolvedURL
        case resolvedAudioURL
        case title
        case fileName
        case mode
        case templateName
        case templateArguments
        case argumentOverride
        case resolverEndpoint
        case resolverDelivery
        case resolverToken
        case status
        case progress
        case receivedBytes
        case totalBytes
        case bytesPerSecond
        case estimatedRemainingSeconds
        case lastProgressAt
        case resumeData
        case createdAt
        case finishedAt
        case localPath
        case message
    }

    init(
        sourceURL: String,
        title: String,
        fileName: String? = nil,
        mode: MediaMode,
        templateName: String,
        templateArguments: String? = nil,
        resolverEndpoint: String? = nil,
        resolverDelivery: ResolverDelivery? = nil,
        resolverToken: String? = nil,
        argumentOverride: String? = nil,
        status: DownloadStatus = .queued
    ) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.resolvedAudioURL = nil
        self.title = title
        self.fileName = fileName
        self.mode = mode
        self.templateName = templateName
        self.templateArguments = templateArguments
        self.argumentOverride = argumentOverride
        self.resolverEndpoint = resolverEndpoint
        self.resolverDelivery = resolverDelivery
        self.resolverToken = resolverToken
        self.status = status
        self.progress = 0
        self.receivedBytes = 0
        self.totalBytes = 0
        self.bytesPerSecond = 0
        self.estimatedRemainingSeconds = nil
        self.lastProgressAt = nil
        self.resumeData = nil
        self.createdAt = Date()
    }

    var effectiveArguments: String? {
        argumentOverrideArguments ?? Self.cleanArguments(templateArguments)
    }

    var argumentOverrideArguments: String? {
        Self.cleanArguments(argumentOverride)
    }

    var effectiveArgumentsTitle: String? {
        if argumentOverrideArguments != nil {
            return "yt-dlp override"
        }
        if Self.cleanArguments(templateArguments) != nil {
            return "yt-dlp template"
        }
        return nil
    }

    private static func cleanArguments(_ arguments: String?) -> String? {
        let trimmed = arguments?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        resolvedURL = try container.decodeIfPresent(String.self, forKey: .resolvedURL)
        resolvedAudioURL = try container.decodeIfPresent(String.self, forKey: .resolvedAudioURL)
        title = try container.decode(String.self, forKey: .title)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        mode = try container.decode(MediaMode.self, forKey: .mode)
        templateName = try container.decode(String.self, forKey: .templateName)
        templateArguments = try container.decodeIfPresent(String.self, forKey: .templateArguments)
        argumentOverride = try container.decodeIfPresent(String.self, forKey: .argumentOverride)
        resolverEndpoint = try container.decodeIfPresent(String.self, forKey: .resolverEndpoint)
        resolverDelivery = try container.decodeIfPresent(ResolverDelivery.self, forKey: .resolverDelivery)
        resolverToken = try container.decodeIfPresent(String.self, forKey: .resolverToken)
        status = try container.decode(DownloadStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        receivedBytes = try container.decode(Int64.self, forKey: .receivedBytes)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        bytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .bytesPerSecond) ?? 0
        estimatedRemainingSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .estimatedRemainingSeconds)
        lastProgressAt = try container.decodeIfPresent(Date.self, forKey: .lastProgressAt)
        resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}
