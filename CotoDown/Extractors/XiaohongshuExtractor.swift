import Foundation

/// Xiaohongshu (小红书) video extractor
/// Based on yt-dlp's XiaoHongShu extractor
final class XiaohongshuExtractor: VideoExtractor {
    let platformName = "Xiaohongshu"
    
    private let session: URLSession
    
    init() {
        self.session = CookieStore.configuredSession(referer: "https://www.xiaohongshu.com/")
    }
    
    func canExtract(url: String) -> Bool {
        guard let url = URL(string: url),
              let host = url.host?.lowercased() else {
            return false
        }
        
        return host.contains("xiaohongshu.com") || host.contains("xhslink.com")
    }
    
    func extract(url: String) async throws -> ExtractionResult {
        // Resolve short URL if needed
        let resolvedURL = try await resolveShortURL(url)
        
        guard let noteID = extractNoteID(from: resolvedURL) else {
            throw ExtractionError.invalidURL
        }
        
        // Fetch note page
        let pageURL = "https://www.xiaohongshu.com/explore/\(noteID)"
        guard let requestURL = URL(string: pageURL) else {
            throw ExtractionError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        CookieStore.apply(to: &request, referer: "https://www.xiaohongshu.com/")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(
                NSError(domain: "Xiaohongshu", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)
            )
        }
        
        guard let html = String(data: data, encoding: .utf8) else {
            throw ExtractionError.parseError("Could not decode page")
        }
        
        // Extract __INITIAL_STATE__ JSON
        guard let initialState = extractInitialState(from: html) else {
            throw ExtractionError.parseError("Could not find initial state")
        }
        
        // Parse note data
        return try parseNoteData(initialState: initialState, noteID: noteID, html: html)
    }
    
    // MARK: - Private Methods
    
    private func resolveShortURL(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              url.host?.contains("xhslink.com") == true else {
            return urlString
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        CookieStore.apply(to: &request, referer: "https://www.xiaohongshu.com/")
        
        let (_, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse,
           let location = httpResponse.value(forHTTPHeaderField: "Location") {
            return location
        }
        
        return urlString
    }
    
    private func extractNoteID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        
        // Standard explore URL: /explore/1234567890
        if let exploreIndex = pathComponents.firstIndex(of: "explore"),
           exploreIndex + 1 < pathComponents.count {
            return pathComponents[exploreIndex + 1]
        }
        
        // Discovery URL: /discovery/item/1234567890
        if let itemIndex = pathComponents.firstIndex(of: "item"),
           itemIndex + 1 < pathComponents.count {
            return pathComponents[itemIndex + 1]
        }
        
        return pathComponents.last
    }
    
    private func extractInitialState(from html: String) -> [String: Any]? {
        // Find __INITIAL_STATE__ JSON
        let pattern = "window\\.__INITIAL_STATE__\\s*=\\s*(\\{.+?\\})\\s*(?:;\\s*</script>|;\\s*var)"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range) else {
            return nil
        }
        
        guard let jsonRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        
        let jsonString = String(html[jsonRange])
        
        // Convert JS to JSON (handle undefined, etc.)
        let cleanedJSON = jsonString
            .replacingOccurrences(of: "undefined", with: "null")
            .replacingOccurrences(of: "'", with: "\"")
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            return nil
        }
        
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    
    private func parseNoteData(initialState: [String: Any], noteID: String, html: String) throws -> ExtractionResult {
        // Navigate to note data
        // Path: note.noteDetailMap.{noteID}.note
        guard let noteData = initialState["note"] as? [String: Any],
              let noteDetailMap = noteData["noteDetailMap"] as? [String: Any],
              let noteDetail = noteDetailMap[noteID] as? [String: Any],
              let note = noteDetail["note"] as? [String: Any] else {
            throw ExtractionError.parseError("Could not find note data")
        }
        
        // Extract title
        let title = (note["title"] as? String) ??
                    (note["desc"] as? String) ??
                    extractTitle(from: html) ??
                    "Xiaohongshu Note"
        
        // Extract thumbnail
        let thumbnail = extractThumbnail(from: note) ?? extractThumbnailFromHTML(html)
        
        // Extract video info
        guard let video = note["video"] as? [String: Any],
              let media = video["media"] as? [String: Any],
              let stream = media["stream"] as? [String: Any] else {
            throw ExtractionError.parseError("This note does not contain video")
        }
        
        var formats: [VideoFormat] = []
        
        // Parse stream formats (H.264, H.265, AV1)
        for (codec, codecStreams) in stream {
            guard let streams = codecStreams as? [String: Any] else { continue }
            
            for (quality, qualityStreams) in streams {
                guard let streamArray = qualityStreams as? [[String: Any]] else { continue }
                
                for (index, streamInfo) in streamArray.enumerated() {
                    if let format = parseStreamFormat(streamInfo, codec: codec, quality: quality, index: index) {
                        formats.append(format)
                    }
                }
            }
        }
        
        // Check for original video key
        if let originKey = (video["consumer"] as? [String: Any])?["originVideoKey"] as? String {
            let originURL = "https://sns-video-bd.xhscdn.com/\(originKey)"
            if let _ = URL(string: originURL) {
                let originFormat = VideoFormat(
                    id: "xhs-original",
                    url: originURL,
                    quality: "original",
                    mimeType: "video/mp4",
                    width: nil,
                    height: nil,
                    bitrate: nil,
                    fileSize: nil,
                    fps: nil,
                    videoCodec: nil,
                    audioCodec: nil,
                    hasVideo: true,
                    hasAudio: true
                )
                formats.append(originFormat)
            }
        }
        
        guard !formats.isEmpty else {
            throw ExtractionError.noFormatsFound
        }
        
        // Find best format (prefer original, then highest resolution)
        let bestFormat = formats.first { $0.quality == "original" } ??
                         formats.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }) ??
                         formats.first
        
        // Extract duration
        let duration = (video["duration"] as? Double).map { $0 / 1000.0 }
        
        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnail,
            duration: duration,
            formats: formats,
            bestFormat: bestFormat
        )
    }
    
    private func parseStreamFormat(_ streamInfo: [String: Any], codec: String, quality: String, index: Int) -> VideoFormat? {
        // Get master URL
        guard let masterUrl = streamInfo["masterUrl"] as? String,
              let _ = URL(string: masterUrl) else {
            return nil
        }
        
        let fps = streamInfo["fps"] as? Int
        let width = streamInfo["width"] as? Int
        let height = streamInfo["height"] as? Int
        let videoCodec = streamInfo["videoCodec"] as? String
        let audioCodec = streamInfo["audioCodec"] as? String
        let videoBitrate = streamInfo["videoBitrate"] as? Int64
        let audioBitrate = streamInfo["audioBitrate"] as? Int64
        let size = streamInfo["size"] as? Int64
        let qualityType = streamInfo["qualityType"] as? String
        
        var qualityLabel = qualityType ?? quality
        if let height {
            qualityLabel = "\(height)p"
        }
        
        return VideoFormat(
            id: "xhs-\(codec)-\(quality)-\(index)",
            url: masterUrl,
            quality: qualityLabel,
            mimeType: "video/mp4",
            width: width,
            height: height,
            bitrate: videoBitrate,
            fileSize: size,
            fps: fps.map { Double($0) },
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            hasVideo: true,
            hasAudio: true
        )
    }
    
    private func extractTitle(from note: [String: Any]) -> String? {
        return note["title"] as? String ?? note["desc"] as? String
    }
    
    private func extractThumbnail(from note: [String: Any]) -> String? {
        // Try to get thumbnail from imageList
        if let imageList = note["imageList"] as? [[String: Any]],
           let firstImage = imageList.first {
            return firstImage["urlDefault"] as? String ?? firstImage["urlPre"] as? String
        }
        return nil
    }
    
    private func extractTitle(from html: String) -> String? {
        let patterns = [
            "<title[^>]*>(.+?)</title>",
            "og:title\"\\s+content=\"([^\"]+)\""
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(html.startIndex..., in: html)
                if let match = regex.firstMatch(in: html, range: range) {
                    if let titleRange = Range(match.range(at: 1), in: html) {
                        let title = String(html[titleRange])
                            .replacingOccurrences(of: " - 小红书", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty {
                            return title
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func extractThumbnailFromHTML(_ html: String) -> String? {
        let pattern = "og:image\"\\s+content=\"([^\"]+)\""
        
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range) {
                if let urlRange = Range(match.range(at: 1), in: html) {
                    var url = String(html[urlRange])
                    if url.hasPrefix("//") {
                        url = "https:" + url
                    }
                    return url
                }
            }
        }
        
        return nil
    }
}
