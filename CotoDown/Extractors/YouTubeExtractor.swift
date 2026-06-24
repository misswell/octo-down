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
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        self.session = URLSession(configuration: configuration)
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
        
        let (data, response) = try await session.data(from: requestURL)
        
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
        
        let (jsData, _) = try await session.data(from: playerJSURL)
        guard let playerJS = String(data: jsData, encoding: .utf8) else {
            throw ExtractionError.parseError("Could not decode player JS")
        }
        
        // Extract signature function from player JS
        guard let sigFunc = extractSignatureFunction(from: playerJS) else {
            throw ExtractionError.parseError("Could not extract signature function")
        }
        
        // Extract formats and decrypt signatures
        let videoDetails = playerResponse["videoDetails"] as? [String: Any] ?? [:]
        let title = videoDetails["title"] as? String ?? "YouTube Video"
        let thumbnail = (videoDetails["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnail?.last?["url"] as? String
        let durationSeconds = Double(videoDetails["lengthSeconds"] as? String ?? "0") ?? 0
        
        guard let streamingData = playerResponse["streamingData"] as? [String: Any] else {
            throw ExtractionError.noFormatsFound
        }
        
        var formats: [VideoFormat] = []
        
        // Process all formats
        let allFormats = (streamingData["formats"] as? [[String: Any]] ?? []) +
                        (streamingData["adaptiveFormats"] as? [[String: Any]] ?? [])
        
        for (index, format) in allFormats.enumerated() {
            var urlString: String?
            
            if let url = format["url"] as? String, !url.isEmpty {
                urlString = url
            } else if let cipher = format["signatureCipher"] as? String ?? format["cipher"] as? String {
                // Decrypt signature
                urlString = try await decryptCipher(cipher, sigFunc: sigFunc)
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
        
        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnailURL,
            duration: durationSeconds > 0 ? durationSeconds : nil,
            formats: formats,
            bestFormat: bestFormat
        )
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
        // Create WKWebView to execute JavaScript
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let configuration = WKWebViewConfiguration()
                let webView = WKWebView(frame: .zero, configuration: configuration)
                
                // Build JavaScript to execute
                let js = """
                \(funcBody)
                var result = (function(a) {
                    a = a.split("");
                    \(extractFunctionBody(from: funcBody))
                    return a.join("");
                })("\(input)");
                result;
                """
                
                webView.evaluateJavaScript(js) { result, error in
                    if let error {
                        continuation.resume(throwing: ExtractionError.parseError("Signature decryption failed: \(error.localizedDescription)"))
                        return
                    }
                    
                    if let signature = result as? String {
                        continuation.resume(returning: signature)
                    } else {
                        continuation.resume(throwing: ExtractionError.parseError("Invalid signature result"))
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
