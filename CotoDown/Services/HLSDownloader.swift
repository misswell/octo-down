import Foundation

struct HLSDownloadProgress: Sendable {
    var completedSegments: Int
    var totalSegments: Int
    var receivedBytes: Int64
}

enum HLSDownloadError: LocalizedError {
    case invalidPlaylistURL
    case invalidPlaylist
    case encryptedStreamUnsupported
    case liveStreamUnsupported
    case noSegments

    var errorDescription: String? {
        switch self {
        case .invalidPlaylistURL:
            "Invalid HLS playlist URL."
        case .invalidPlaylist:
            "The HLS playlist could not be parsed."
        case .encryptedStreamUnsupported:
            "Encrypted HLS streams are not supported yet."
        case .liveStreamUnsupported:
            "Live HLS streams are not supported yet."
        case .noSegments:
            "The HLS playlist did not contain media segments."
        }
    }
}

struct HLSDownloader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        playlistURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (HLSDownloadProgress) -> Void
    ) async throws {
        let mediaPlaylist = try await resolveMediaPlaylist(from: playlistURL)
        guard mediaPlaylist.isLive == false else {
            throw HLSDownloadError.liveStreamUnsupported
        }
        guard mediaPlaylist.isEncrypted == false else {
            throw HLSDownloadError.encryptedStreamUnsupported
        }
        guard !mediaPlaylist.segments.isEmpty else {
            throw HLSDownloadError.noSegments
        }

        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).part")
        try? fileManager.removeItem(at: temporaryURL)
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)

        var receivedBytes: Int64 = 0
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? handle.close()
            try? fileManager.removeItem(at: temporaryURL)
        }

        for (index, segmentURL) in mediaPlaylist.segments.enumerated() {
            try Task.checkCancellation()
            var request = URLRequest(url: segmentURL)
            CookieStore.apply(to: &request, referer: playlistURL.absoluteString)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            try handle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            progress(
                HLSDownloadProgress(
                    completedSegments: index + 1,
                    totalSegments: mediaPlaylist.segments.count,
                    receivedBytes: receivedBytes
                )
            )
        }

        try handle.close()
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func resolveMediaPlaylist(from playlistURL: URL) async throws -> MediaPlaylist {
        let rootPlaylist = try await loadPlaylist(from: playlistURL)
        if let variantURL = rootPlaylist.bestVariantURL {
            return try await loadPlaylist(from: variantURL).mediaPlaylist(baseURL: variantURL)
        }
        return rootPlaylist.mediaPlaylist(baseURL: playlistURL)
    }

    private func loadPlaylist(from url: URL) async throws -> ParsedPlaylist {
        var request = URLRequest(url: url)
        CookieStore.apply(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try ParsedPlaylist(text: text, baseURL: url)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendResolverError.httpStatus(http.statusCode)
        }
    }
}

private struct MediaPlaylist {
    var segments: [URL]
    var isEncrypted: Bool
    var isLive: Bool
}

private struct ParsedPlaylist {
    private struct Variant {
        var url: URL
        var bandwidth: Int
    }

    private var variants: [Variant] = []
    private var segmentURLs: [URL] = []
    private var encrypted = false
    private var ended = false

    var bestVariantURL: URL? {
        variants.max { $0.bandwidth < $1.bandwidth }?.url
    }

    init(text: String, baseURL: URL) throws {
        let rawLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard rawLines.first == "#EXTM3U" else {
            throw HLSDownloadError.invalidPlaylist
        }

        var pendingVariantBandwidth: Int?
        for line in rawLines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingVariantBandwidth = Self.attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
                continue
            }

            if line.hasPrefix("#EXT-X-KEY") {
                let method = Self.attribute("METHOD", in: line)?.uppercased()
                encrypted = method != nil && method != "NONE"
                continue
            }

            if line == "#EXT-X-ENDLIST" {
                ended = true
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            if let bandwidth = pendingVariantBandwidth {
                variants.append(Variant(url: url, bandwidth: bandwidth))
                pendingVariantBandwidth = nil
            } else {
                segmentURLs.append(url)
            }
        }
    }

    func mediaPlaylist(baseURL: URL) -> MediaPlaylist {
        MediaPlaylist(
            segments: segmentURLs,
            isEncrypted: encrypted,
            isLive: !ended,
        )
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        let prefix = "\(name)="
        guard let range = line.range(of: prefix) else { return nil }
        let tail = line[range.upperBound...]
        if tail.first == "\"" {
            let quoted = tail.dropFirst()
            return quoted.split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
        return tail
            .split(separator: ",", maxSplits: 1)
            .first
            .map(String.init)
    }
}
