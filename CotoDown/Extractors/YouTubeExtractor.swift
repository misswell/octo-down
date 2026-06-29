import Foundation
import WebKit

/// YouTube video extractor with real signature decryption
/// Uses WKWebView to execute YouTube's JavaScript signature functions
final class YouTubeExtractor: NSObject, VideoExtractor {
    let platformName = "YouTube"
    
    private let session: URLSession
    private var webView: WKWebView?
    private var playerJS: String?
    
    override init() {
        self.session = CookieStore.configuredSession()
        super.init()
    }
    
    func canExtract(url: String) -> Bool {
        guard let url = URL(string: url),
              let host = url.host?.lowercased() else {
            return false
        }
        
        return host.contains("youtube.com") || host.contains("youtu.be")
    }
    
    func extract(url: String) async throws -> ExtractionResult {
        guard let videoID = extractVideoID(from: url) else {
            throw ExtractionError.invalidURL
        }
        
        // Fetch video page
        let pageURL = "https://www.youtube.com/watch?v=\(videoID)"
        guard let requestURL = URL(string: pageURL) else {
            throw ExtractionError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        CookieStore.apply(to: &request, referer: "https://www.youtube.com/")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(
                NSError(domain: "YouTube", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)
            )
        }
        
        guard let html = String(data: data, encoding: .utf8) else {
            throw ExtractionError.parseError("Could not decode page")
        }
        
        // Extract player response
        guard let playerResponse = extractPlayerResponse(from: html) else {
            throw ExtractionError.parseError("Could not find player response")
        }
        
        // Extract player JS URL for signature decryption
        let playerJSURL = extractPlayerJSURL(from: html)
        
        // Parse formats
        let result = try parsePlayerResponse(playerResponse, videoID: videoID)
        
        // If we have formats with direct URLs, return them
        if !result.formats.isEmpty {
            return result
        }
        
        // Otherwise, we need to decrypt signatures
        guard let playerJSURL else {
            throw ExtractionError.parseError("Could not find player JS URL")
        }
        
        // Load player JS and decrypt signatures
        return try await decryptSignatures(playerResponse: playerResponse, playerJSURL: playerJSURL, videoID: videoID)
    }
    
    // MARK: - Private Methods
    

    func canExtractPlaylist(url: String) -> Bool {
        guard let url = URL(string: url),
              let host = url.host?.lowercased() else {
            return false
        }
        guard host.contains("youtube.com") || host.contains("youtu.be") else {
            return false
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let list = components.queryItems?.first(where: { $0.name == "list" })?.value,
               !list.isEmpty {
                return true
            }
        }
        return url.pathComponents.contains("playlist")
    }

    func extractPlaylist(url: String) async throws -> PlaylistResult {
        guard let url = URL(string: url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let listID = components.queryItems?.first(where: { $0.name == "list" })?.value ?? 
                    url.pathComponents.last
        else {
            throw ExtractionError.invalidURL
        }

        let playlistURL = "https://www.youtube.com/playlist?list=\(listID)"
        var request = URLRequest(url: URL(string: playlistURL)!)
        CookieStore.apply(to: &request, referer: "https://www.youtube.com/")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else {
            throw ExtractionError.networkError(NSError(domain: "YouTube", code: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }

        // Try to extract playlist metadata from ytInitialData
        var playlistTitle = "Playlist"
        var entries: [PlaylistEntry] = []

        if let initialData = extractJSON(from: html, variable: "ytInitialData") {
            playlistTitle = extractPlaylistTitle(from: initialData)
            entries = extractPlaylistEntries(from: initialData)
        }

        // Fallback: extract from HTML
        if entries.isEmpty {
            entries = extractPlaylistEntriesFromHTML(html)
        }
        if playlistTitle == "Playlist" {
            playlistTitle = extractPlaylistTitleFromHTML(html)
        }

        return PlaylistResult(
            title: playlistTitle,
            thumbnailURL: nil,
            entries: entries
        )
    }

    private func extractJSON(from html: String, variable: String) -> [[String: Any]]? {
        let pattern = "\(variable)\\s*=\\s*(\\{.+?\\});"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let jsonRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        let jsonString = String(html[jsonRange])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return [json]
    }

    private func extractPlaylistTitle(from initialData: [[String: Any]]) -> String {
        guard let data = initialData.first else { return "Playlist" }
        if let sidebar = data["sidebar"] as? [String: Any],
           let playlistSidebarRenderer = sidebar["playlistSidebarRenderer"] as? [String: Any],
           let items = playlistSidebarRenderer["items"] as? [[String: Any]],
           let firstItem = items.first,
           let playlistSidebarPrimaryInfoRenderer = firstItem["playlistSidebarPrimaryInfoRenderer"] as? [String: Any],
           let title = playlistSidebarPrimaryInfoRenderer["title"] as? [String: Any],
           let runs = title["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return "Playlist"
    }

    private func extractPlaylistEntries(from initialData: [[String: Any]]) -> [PlaylistEntry] {
        guard let data = initialData.first else { return [] }
        var entries: [PlaylistEntry] = []

        if let contents = data["contents"] as? [String: Any],
           let twoColumnBrowseResultsRenderer = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
           let tabs = twoColumnBrowseResultsRenderer["tabs"] as? [[String: Any]] {
            for tab in tabs {
                if let tabRenderer = tab["tabRenderer"] as? [String: Any],
                   let content = tabRenderer["content"] as? [String: Any],
                   let sectionListRenderer = content["sectionListRenderer"] as? [String: Any],
                   let contents = sectionListRenderer["contents"] as? [[String: Any]] {
                    entries = parsePlaylistVideoItems(contents)
                    if !entries.isEmpty { break }
                }
            }
        }

        return entries
    }

    private func parsePlaylistVideoItems(_ contents: [[String: Any]]) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        for content in contents {
            if let itemSection = content["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSection["contents"] as? [[String: Any]] {
                for item in itemContents {
                    if let playlistVideoListRenderer = item["playlistVideoListRenderer"] as? [String: Any],
                       let videoItems = playlistVideoListRenderer["contents"] as? [[String: Any]] {
                        for videoItem in videoItems {
                            if let entry = parsePlaylistVideoItem(videoItem) {
                                entries.append(entry)
                            }
                        }
                    }
                }
            }
        }
        return entries
    }

    private func parsePlaylistVideoItem(_ item: [String: Any]) -> PlaylistEntry? {
        guard let playlistVideoRenderer = item["playlistVideoRenderer"] as? [String: Any],
              let videoID = playlistVideoRenderer["videoId"] as? String,
              let titleInfo = playlistVideoRenderer["title"] as? [String: Any],
              let runs = titleInfo["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String
        else {
            return nil
        }

        let duration: Double?
        if let lengthSeconds = playlistVideoRenderer["lengthSeconds"] as? String {
            duration = Double(lengthSeconds)
        } else {
            duration = nil
        }

        let thumbnailURL: String?
        if let thumbnails = playlistVideoRenderer["thumbnail"] as? [String: Any],
           let thumbnailsArray = thumbnails["thumbnails"] as? [[String: Any]],
           let last = thumbnailsArray.last,
           let url = last["url"] as? String {
            thumbnailURL = url
        } else {
            thumbnailURL = nil
        }

        return PlaylistEntry(
            id: videoID,
            title: title,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            duration: duration,
            thumbnailURL: thumbnailURL
        )
    }

    private func extractPlaylistEntriesFromHTML(_ html: String) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        let pattern = "watch\\?v=([a-zA-Z0-9_-]{11})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return entries
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let videoRange = Range(match.range(at: 1), in: html)
            else { continue }
            let videoID = String(html[videoRange])
            if seen.insert(videoID).inserted {
                entries.append(PlaylistEntry(
                    id: videoID,
                    title: "Video \(videoID)",
                    url: "https://www.youtube.com/watch?v=\(videoID)",
                    duration: nil,
                    thumbnailURL: nil
                ))
            }
        }
        return entries
    }

    private func extractPlaylistTitleFromHTML(_ html: String) -> String {
        let patterns = [
            "<title>(.+?) - YouTube</title>",
            #"\"title\"\s*:\s*\"([^\"]+)\""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let titleRange = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[titleRange])
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }
        return "Playlist"
    }

    private func extractVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        if url.host?.contains("youtube.com") == true {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value
        }
        
        if url.host?.contains("youtu.be") == true {
            let path = url.path
            return path.isEmpty ? nil : String(path.dropFirst())
        }
        
        if url.path.contains("/embed/") {
            let components = url.path.components(separatedBy: "/embed/")
            return components.last
        }
        
        return nil
    }
    
    private func extractPlayerResponse(from html: String) -> [String: Any]? {
        // Try to find ytInitialPlayerResponse
        let patterns = [
            "ytInitialPlayerResponse\\s*=\\s*({.+?})\\s*;",
            "var\\s+ytInitialPlayerResponse\\s*=\\s*({.+?})\\s*;"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let range = NSRange(html.startIndex..., in: html)
                if let match = regex.firstMatch(in: html, range: range) {
                    if let jsonRange = Range(match.range(at: 1), in: html) {
                        let jsonString = String(html[jsonRange])
                        if let data = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            return json
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func extractPlayerJSURL(from html: String) -> String? {
        // Find player JS URL
        let pattern = "\"jsUrl\"\\s*:\\s*\"([^\"]+\\.js)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range) {
                if let urlRange = Range(match.range(at: 1), in: html) {
                    var url = String(html[urlRange])
                    if url.hasPrefix("/") {
                        url = "https://www.youtube.com" + url
                    }
                    return url
                }
            }
        }
        
        return nil
    }
    
    private func parsePlayerResponse(_ response: [String: Any], videoID: String) throws -> ExtractionResult {
        let videoDetails = response["videoDetails"] as? [String: Any] ?? [:]
        let title = videoDetails["title"] as? String ?? "YouTube Video"
        let thumbnail = (videoDetails["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnail?.last?["url"] as? String
        let durationSeconds = Double(videoDetails["lengthSeconds"] as? String ?? "0") ?? 0
        
        guard let streamingData = response["streamingData"] as? [String: Any] else {
            throw ExtractionError.noFormatsFound
        }
        
        var formats: [VideoFormat] = []
        
        // Extract formats with direct URLs (no signature required)
        if let formatList = streamingData["formats"] as? [[String: Any]] {
            for (index, format) in formatList.enumerated() {
                if let videoFormat = parseFormat(format, id: "regular-\(index)", requiresSig: false) {
                    formats.append(videoFormat)
                }
            }
        }
        
        // Extract adaptive formats (may require signature)
        if let adaptiveList = streamingData["adaptiveFormats"] as? [[String: Any]] {
            for (index, format) in adaptiveList.enumerated() {
                if let videoFormat = parseFormat(format, id: "adaptive-\(index)", requiresSig: true) {
                    formats.append(videoFormat)
                }
            }
        }
        
        let bestFormat = formats
            .filter { $0.hasVideo && $0.hasAudio }
            .max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
            ?? formats.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
            ?? formats.first
        
        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnailURL,
            duration: durationSeconds > 0 ? durationSeconds : nil,
            formats: formats,
            bestFormat: bestFormat
        )
    }
    
    private func parseFormat(_ format: [String: Any], id: String, requiresSig: Bool) -> VideoFormat? {
        // Get URL
        var urlString: String?
        var needsSignature = false
        
        if let url = format["url"] as? String, !url.isEmpty {
            urlString = url
        } else if requiresSig {
            // This format needs signature decryption
            needsSignature = true
            // We'll handle this in decryptSignatures
            return nil
        } else {
            return nil
        }
        
        guard let urlString, let _ = URL(string: urlString) else {
            return nil
        }
        
        let mimeType = format["mimeType"] as? String ?? ""
        let hasVideo = mimeType.contains("video")
        let hasAudio = mimeType.contains("audio")
        
        return VideoFormat(
            id: id,
            url: urlString,
            quality: format["qualityLabel"] as? String ?? format["quality"] as? String ?? "Unknown",
            mimeType: mimeType,
            width: format["width"] as? Int,
            height: format["height"] as? Int,
            bitrate: format["bitrate"] as? Int64,
            fileSize: (format["contentLength"] as? String).flatMap { Int64($0) },
            fps: format["fps"] as? Double,
            videoCodec: extractCodec(from: mimeType, type: "video"),
            audioCodec: extractCodec(from: mimeType, type: "audio"),
            hasVideo: hasVideo,
            hasAudio: hasAudio
        )
    }
    
    private func extractCodec(from mimeType: String, type: String) -> String? {
        guard let codecsRange = mimeType.range(of: "codecs=\"") else { return nil }
        let codecsString = String(mimeType[codecsRange.upperBound...])
        guard let endQuote = codecsString.range(of: "\"") else { return nil }
        let codecs = String(codecsString[..<endQuote.lowerBound])
        
        let codecList = codecs.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        
        if type == "video" {
            return codecList.first { $0.hasPrefix("avc") || $0.hasPrefix("vp") || $0.hasPrefix("hev") }
        } else {
            return codecList.first { $0.hasPrefix("mp4a") || $0.hasPrefix("opus") || $0.hasPrefix("vorbis") }
        }
    }
    
    // MARK: - Signature Decryption
    
    private func decryptSignatures(playerResponse: [String: Any], playerJSURL: String, videoID: String) async throws -> ExtractionResult {
        // Load player JS
        guard let playerJSURL = URL(string: playerJSURL) else {
            throw ExtractionError.parseError("Invalid player JS URL")
        }
        
        var request = URLRequest(url: playerJSURL)
        CookieStore.apply(to: &request, referer: "https://www.youtube.com/")
        let (jsData, _) = try await session.data(for: request)
        guard let playerJS = String(data: jsData, encoding: .utf8) else {
            throw ExtractionError.parseError("Could not decode player JS")
        }
        
        // Extract signature function from player JS
        guard let sigFunc = extractSignatureFunction(from: playerJS) else {
            guard let altSigFunc = extractSignatureFunctionAlt(from: playerJS) else {
                throw ExtractionError.parseError("Could not extract signature function")
            }
            self.playerJS = playerJS
            return try await decryptFormats(playerResponse: playerResponse, sigFunc: altSigFunc, videoID: videoID)
        }
        self.playerJS = playerJS
        return try await decryptFormats(playerResponse: playerResponse, sigFunc: sigFunc, videoID: videoID)
    }

    private func decryptFormats(
        playerResponse: [String: Any],
        sigFunc: String,
        videoID: String
    ) async throws -> ExtractionResult {
        if let playerJS, nTransformFunction == nil {
            nTransformFunction = extractNTransformFunction(from: playerJS)
        }

        let videoDetails = playerResponse["videoDetails"] as? [String: Any] ?? [:]
        let title = videoDetails["title"] as? String ?? "YouTube Video"
        let thumbnail = (videoDetails["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnail?.last?["url"] as? String
        let durationSeconds = Double(videoDetails["lengthSeconds"] as? String ?? "0") ?? 0

        guard let streamingData = playerResponse["streamingData"] as? [String: Any] else {
            throw ExtractionError.noFormatsFound
        }

        var formats: [VideoFormat] = []

        let allFormats = (streamingData["formats"] as? [[String: Any]] ?? []) +
                        (streamingData["adaptiveFormats"] as? [[String: Any]] ?? [])

        for (index, format) in allFormats.enumerated() {
            var urlString: String?

            if let url = format["url"] as? String, !url.isEmpty {
                urlString = url
            } else if let cipher = format["signatureCipher"] as? String ?? format["cipher"] as? String {
                urlString = try await decryptCipher(cipher, sigFunc: sigFunc)
            }

            if let urlString, let nTransformFunction {
                urlString = try await decryptNParam(urlString, nTransformFunc: nTransformFunction)
            }

            guard let urlString, let _ = URL(string: urlString) else {
                continue
            }

            let mimeType = format["mimeType"] as? String ?? ""
            let hasVideo = mimeType.contains("video")
            let hasAudio = mimeType.contains("audio")

            let videoFormat = VideoFormat(
                id: "yt-\(index)",
                url: urlString,
                quality: format["qualityLabel"] as? String ?? format["quality"] as? String ?? "Unknown",
                mimeType: mimeType,
                width: format["width"] as? Int,
                height: format["height"] as? Int,
                bitrate: format["bitrate"] as? Int64,
                fileSize: (format["contentLength"] as? String).flatMap { Int64($0) },
                fps: format["fps"] as? Double,
                videoCodec: extractCodec(from: mimeType, type: "video"),
                audioCodec: extractCodec(from: mimeType, type: "audio"),
                hasVideo: hasVideo,
                hasAudio: hasAudio
            )

            formats.append(videoFormat)
        }

        guard !formats.isEmpty else {
            throw ExtractionError.noFormatsFound
        }

        let bestFormat = formats
            .filter { $0.hasVideo && $0.hasAudio }
            .max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
            ?? formats.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
            ?? formats.first

        // Extract subtitles
        let subtitles = extractSubtitles(from: playerResponse)

        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnailURL,
            duration: durationSeconds > 0 ? durationSeconds : nil,
            formats: formats,
            bestFormat: bestFormat,
            subtitles: subtitles
        )
    }

    private func extractSubtitles(from playerResponse: [String: Any]) -> [SubtitleTrack] {
        guard let captions = playerResponse["captions"] as? [String: Any],
              let playerCaptionsTracklistRenderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let captionTracks = playerCaptionsTracklistRenderer["captionTracks"] as? [[String: Any]]
        else {
            return []
        }

        var tracks: [SubtitleTrack] = []
        for track in captionTracks {
            guard let languageCode = track["languageCode"] as? String,
                  let baseUrl = track["baseUrl"] as? String,
                  let name = track["name"] as? [String: Any],
                  let simpleText = name["simpleText"] as? String ?? (name["runs"] as? [[String: Any]])?.first?["text"] as? String
            else {
                continue
            }

            let isAutoGenerated = (track["kind"] as? String) == "asr"
            let isOriginal = languageCode == "en" || languageCode == "original"

            var subtitleURL = baseUrl
            if !subtitleURL.contains("fmt=") {
                subtitleURL += (subtitleURL.contains("?") ? "&" : "?") + "fmt=srv3"
            }

            tracks.append(SubtitleTrack(
                id: languageCode,
                languageCode: languageCode,
                languageName: simpleText,
                url: subtitleURL,
                isAutoGenerated: isAutoGenerated,
                isOriginal: isOriginal
            ))
        }
        return tracks
    }

    private func extractSignatureFunctionAlt(from playerJS: String) -> String? {
        let pattern = "([a-zA-Z0-9$]+)\\s*=\\s*function\\(a\\)\\{a=a\\.split\\(\"\"\\);(.+?);return a\\.join\\(\"\"\\)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(playerJS.startIndex..., in: playerJS)
        guard let match = regex.firstMatch(in: playerJS, range: range),
              let funcRange = Range(match.range(at: 0), in: playerJS)
        else {
            return nil
        }
        return String(playerJS[funcRange])
    }

    private func extractNTransformFunction(from playerJS: String) -> String? {
        let patterns = [
            "function\\(b\\)\\{b=b\\.split\\(\"\"\\);(.+?);return b\\.join\\(\"\"\\)\\}",
            "var\\s+([a-zA-Z0-9$]+)\\s*=\\s*function\\(b\\)\\{b=b\\.split\\(\"\"\\);(.+?);return b\\.join\\(\"\"\\)\\}"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                continue
            }
            let range = NSRange(playerJS.startIndex..., in: playerJS)
            if let match = regex.firstMatch(in: playerJS, range: range),
               let funcRange = Range(match.range(at: 0), in: playerJS) {
                let funcString = String(playerJS[funcRange])
                if funcString.contains("Number(") || funcString.contains("parseInt") || funcString.contains("splice") {
                    return funcString
                }
            }
        }
        return nil
    }

    private func decryptNParam(_ urlString: String, nTransformFunc: String) async throws -> String? {
        guard var components = URLComponents(string: urlString) else { return urlString }
        let queryItems = components.queryItems ?? []
        guard let nItem = queryItems.first(where: { $0.name == "n" }),
              let nValue = nItem.value,
              !nValue.isEmpty
        else {
            return urlString
        }

        let decryptedN = try await executeSignatureFunction(nTransformFunc, input: nValue)
        var newQueryItems = queryItems
        if let index = newQueryItems.firstIndex(where: { $0.name == "n" }) {
            newQueryItems[index] = URLQueryItem(name: "n", value: decryptedN)
        }
        components.queryItems = newQueryItems
        return components.url?.absoluteString ?? urlString
    }

    private func extractSignatureFunction(from playerJS: String) -> String? {
        // Find the signature function in player JS
        // Pattern: var XX=function(a){a=a.split("");...;return a.join("")};
        let pattern = "var\\s+([a-zA-Z0-9$]+)\\s*=\\s*function\\(a\\)\\{a=a\\.split\\(\"\"\\);([^}]+);return a\\.join\\(\"\"\\)\\}"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let range = NSRange(playerJS.startIndex..., in: playerJS)
        guard let match = regex.firstMatch(in: playerJS, range: range) else {
            return nil
        }
        
        // Extract the function body
        if let funcRange = Range(match.range(at: 0), in: playerJS) {
            return String(playerJS[funcRange])
        }
        
        return nil
    }
    
    private func decryptCipher(_ cipher: String, sigFunc: String) async throws -> String? {
        // Parse cipher
        let params = parseQueryString(cipher)
        
        guard let url = params["url"],
              let encryptedSig = params["s"],
              let sp = params["sp"] ?? Optional("signature") else {
            return nil
        }
        
        // Use WKWebView to decrypt signature
        let decryptedSig = try await executeSignatureFunction(sigFunc, input: encryptedSig)
        
        // Build final URL
        var components = URLComponents(string: url)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: sp, value: decryptedSig))
        components?.queryItems = queryItems
        
        return components?.url?.absoluteString
    }
    
    private func executeSignatureFunction(_ funcBody: String, input: String) async throws -> String {
        let escapedInput = input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let configuration = WKWebViewConfiguration()
                let webView = WKWebView(frame: .zero, configuration: configuration)
                
                let js = """
                var result = (function(a) {
                    a = a.split("");
                    \(self.extractFunctionBody(from: funcBody))
                    return a.join("");
                })("\(escapedInput)");
                result;
                """
                
                webView.evaluateJavaScript(js) { result, error in
                    if let error {
                        let altJS = """
                        \(funcBody)
                        \(self.extractFunctionBody(from: funcBody))
                        "\(escapedInput)";
                        """
                        webView.evaluateJavaScript(altJS) { altResult, altError in
                            if let altError {
                                continuation.resume(throwing: ExtractionError.parseError("Signature decryption failed: \(altError.localizedDescription)"))
                                return
                            }
                            if let signature = altResult as? String {
                                continuation.resume(returning: signature)
                            } else {
                                continuation.resume(throwing: ExtractionError.parseError("Invalid signature result"))
                            }
                        }
                        return
                    }

                    if let signature = result as? String {
                        continuation.resume(returning: signature)
                    } else {
                        continuation.resume(throwing: ExtractionError.parseError("Signature decryption failed: \(error!.localizedDescription)"))
                    }
                }
            }
        }
    }
    
    private func extractFunctionBody(from funcString: String) -> String {
        // Extract the body between { and }
        guard let start = funcString.range(of: "{"),
              let end = funcString.range(of: "}", options: .backwards) else {
            return ""
        }
        
        let body = String(funcString[start.upperBound..<end.lowerBound])
        // Remove the initial a=a.split(""); and final return a.join("");
        return body
            .replacingOccurrences(of: "a=a.split(\"\");", with: "")
            .replacingOccurrences(of: "return a.join(\"\");", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func parseQueryString(_ queryString: String) -> [String: String] {
        var params: [String: String] = [:]
        
        let pairs = queryString.components(separatedBy: "&")
        for pair in pairs {
            let components = pair.components(separatedBy: "=")
            if components.count == 2 {
                let key = components[0].removingPercentEncoding ?? components[0]
                let value = components[1].removingPercentEncoding ?? components[1]
                params[key] = value
            }
        }
        
        return params
    }
}
