import Foundation

struct ResolveRequest: Encodable {
    var url: String
    var template: String
    var mode: String
    var arguments: String
    var delivery: String
    var playlist: Bool
}

private struct ResolverErrorResponse: Decodable {
    var error: String?
}

struct ResolvedLinkInfo: Decodable, Equatable {
    var title: String?
    var uploader: String?
    var webpageURL: String?
    var thumbnail: String?
    var extractor: String?
    var durationSeconds: Double?
    var entryCount: Int?
    var formats: [ResolvedFormatInfo]?
}

struct ResolvedFormatInfo: Decodable, Equatable, Identifiable {
    var id: String
    var fileExtension: String?
    var resolution: String?
    var height: Int?
    var fps: Double?
    var filesizeBytes: Int64?
    var bitrateKbps: Double?
    var note: String?
    var videoCodec: String?
    var audioCodec: String?
    var hasVideo: Bool
    var hasAudio: Bool

    var downloadArguments: String {
        if hasVideo && !hasAudio {
            return "-f \(id)+ba/b"
        }
        if hasAudio && !hasVideo {
            return "-f \(id)/ba"
        }
        return "-f \(id)/b"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension)
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        fps = try container.decodeIfPresent(Double.self, forKey: .fps)
        filesizeBytes = try container.decodeIfPresent(Int64.self, forKey: .filesizeBytes)
        bitrateKbps = try container.decodeIfPresent(Double.self, forKey: .bitrateKbps)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        videoCodec = try container.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
        hasVideo = try container.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? (videoCodec != nil)
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? (audioCodec != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileExtension = "extension"
        case resolution
        case height
        case fps
        case filesizeBytes
        case bitrateKbps
        case note
        case videoCodec
        case audioCodec
        case hasVideo
        case hasAudio
    }
}

struct ResolvedMediaItem: Decodable, Equatable {
    var url: String
    var title: String?
    var filename: String?
}

struct ResolveResponse: Decodable {
    var url: String?
    var title: String?
    var filename: String?
    var entries: [ResolvedMediaItem]?

    func mediaItems() throws -> [ResolvedMediaItem] {
        if let entries, !entries.isEmpty {
            return entries
        }

        guard let url else {
            throw BackendResolverError.invalidResolvedURL
        }

        return [
            ResolvedMediaItem(url: url, title: title, filename: filename)
        ]
    }
}

enum BackendResolverError: LocalizedError {
    case missingEndpoint
    case invalidEndpoint
    case invalidResolvedURL
    case resolverMessage(String)
    case httpStatus(Int)
    case needsResolver(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            "No resolver configured. Direct download links (mp4, mp3, etc.) work without resolver. For YouTube, Vimeo, etc., configure a resolver in Settings."
        case .invalidEndpoint:
            "The resolver endpoint is not a valid URL."
        case .invalidResolvedURL:
            "The resolver returned an invalid media URL."
        case .resolverMessage(let message):
            message
        case .httpStatus(let statusCode):
            "The resolver returned HTTP \(statusCode)."
        case .needsResolver(let host):
            "This link (\(host)) requires a resolver service. Direct download links (mp4, mp3, etc.) work without resolver."
        }
    }
}

struct BackendResolver {
    /// Check if a URL needs resolver service (YouTube, etc.)
    static func needsResolver(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let host = url.host?.lowercased() ?? ""
        let resolverHosts = ["youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
                             "vimeo.com", "www.vimeo.com", "dailymotion.com", "www.dailymotion.com",
                             "twitch.tv", "www.twitch.tv", "twitter.com", "www.twitter.com",
                             "x.com", "www.x.com", "instagram.com", "www.instagram.com",
                             "tiktok.com", "www.tiktok.com"]
        return resolverHosts.contains(host)
    }
    
    /// Get a user-friendly message about whether a URL can be downloaded
    static func downloadStatusMessage(for urlString: String, hasResolver: Bool) -> String {
        if isDirectDownloadURL(urlString) {
            return "✅ Direct download - no resolver needed"
        }
        
        if needsResolver(urlString) {
            if hasResolver {
                return "🔄 Will use resolver to extract video"
            } else {
                return "⚠️ Requires resolver - configure in Settings"
            }
        }
        
        return "🔗 Will attempt direct download"
    }
    
    func resolve(
        sourceURL: String,
        template: DownloadTemplate,
        argumentOverride: String?,
        endpoint: String,
        token: String,
        delivery: ResolverDelivery
    ) async throws -> ResolveResponse {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if URL needs resolver
        if trimmedEndpoint.isEmpty && Self.needsResolver(sourceURL) {
            guard let url = URL(string: sourceURL),
                  let host = url.host else {
                throw BackendResolverError.missingEndpoint
            }
            throw BackendResolverError.needsResolver(host)
        }
        
        guard !trimmedEndpoint.isEmpty else {
            throw BackendResolverError.missingEndpoint
        }
        guard let endpointURL = URL(string: trimmedEndpoint) else {
            throw BackendResolverError.invalidEndpoint
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyAuthorization(token: token, to: &request)
        request.httpBody = try JSONEncoder().encode(
            Self.resolveRequest(
                sourceURL: sourceURL,
                template: template,
                argumentOverride: argumentOverride,
                delivery: delivery
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validateResponse(response, data: data)

        let resolved = try JSONDecoder().decode(ResolveResponse.self, from: data)
        for item in try resolved.mediaItems() {
            guard URL(string: item.url) != nil else {
                throw BackendResolverError.invalidResolvedURL
            }
        }

        return resolved
    }

    func info(
        sourceURL: String,
        template: DownloadTemplate,
        argumentOverride: String?,
        endpoint: String,
        token: String
    ) async throws -> ResolvedLinkInfo {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if URL needs resolver
        if trimmedEndpoint.isEmpty && Self.needsResolver(sourceURL) {
            guard let url = URL(string: sourceURL),
                  let host = url.host else {
                throw BackendResolverError.missingEndpoint
            }
            throw BackendResolverError.needsResolver(host)
        }
        
        guard !trimmedEndpoint.isEmpty else {
            throw BackendResolverError.missingEndpoint
        }
        guard let infoURL = Self.serviceURL(from: trimmedEndpoint, pathComponent: "info") else {
            throw BackendResolverError.invalidEndpoint
        }

        var request = URLRequest(url: infoURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyAuthorization(token: token, to: &request)
        request.httpBody = try JSONEncoder().encode(
            Self.resolveRequest(
                sourceURL: sourceURL,
                template: template,
                argumentOverride: argumentOverride,
                delivery: .direct
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validateResponse(response, data: data)

        return try JSONDecoder().decode(ResolvedLinkInfo.self, from: data)
    }

    static func applyAuthorization(token: String, to request: inout URLRequest) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func resolveRequest(
        sourceURL: String,
        template: DownloadTemplate,
        argumentOverride: String?,
        delivery: ResolverDelivery
    ) -> ResolveRequest {
        let arguments = effectiveArguments(template: template, override: argumentOverride)
        return ResolveRequest(
            url: sourceURL,
            template: template.name,
            mode: template.mode.rawValue,
            arguments: arguments,
            delivery: delivery.rawValue,
            playlist: template.mode == .playlist || requestsPlaylist(arguments)
        )
    }

    private static func effectiveArguments(template: DownloadTemplate, override: String?) -> String {
        let trimmedOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOverride?.isEmpty == false ? trimmedOverride! : template.arguments
    }

    private static func requestsPlaylist(_ arguments: String) -> Bool {
        let normalized = " \(arguments) ".lowercased()
        return normalized.contains(" --yes-playlist ")
            || normalized.contains(" --yes-playlist=")
            || normalized.contains(" --playlist-start ")
            || normalized.contains(" --playlist-start=")
            || normalized.contains(" --playlist-end ")
            || normalized.contains(" --playlist-end=")
            || normalized.contains(" --playlist-items ")
            || normalized.contains(" --playlist-items=")
    }

    private static func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(httpResponse.statusCode) else { return }

        if let decoded = try? JSONDecoder().decode(ResolverErrorResponse.self, from: data),
           let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            throw BackendResolverError.resolverMessage(message)
        }

        throw BackendResolverError.httpStatus(httpResponse.statusCode)
    }

    private static func serviceURL(from endpoint: String, pathComponent: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else {
            return nil
        }

        var pathComponents = components.path.split(separator: "/").map(String.init)
        if pathComponents.last == "resolve" {
            pathComponents.removeLast()
        }
        pathComponents.append(pathComponent)
        components.path = "/" + pathComponents.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
