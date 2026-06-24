import Foundation
import CryptoKit

/// Bilibili video extractor with WBI signature support
/// Based on yt-dlp's Bilibili extractor
final class BilibiliExtractor: VideoExtractor {
    let platformName = "Bilibili"
    
    private let session: URLSession
    private var wbiKey: String?
    private var wbiKeyTimestamp: TimeInterval = 0
    private let wbiKeyCacheTimeout: TimeInterval = 30
    
    // WBI key mixin table from yt-dlp
    private let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52
    ]
    
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://www.bilibili.com"
        ]
        self.session = URLSession(configuration: configuration)
    }
    
    func canExtract(url: String) -> Bool {
        guard let url = URL(string: url),
              let host = url.host?.lowercased() else {
            return false
        }
        
        return host.contains("bilibili.com") || host.contains("b23.tv")
    }
    
    func extract(url: String) async throws -> ExtractionResult {
        // Resolve short URL if needed
        let resolvedURL = try await resolveShortURL(url)
        
        guard let videoID = extractVideoID(from: resolvedURL) else {
            throw ExtractionError.invalidURL
        }
        
        // Fetch video info
        let videoInfo = try await fetchVideoInfo(videoID: videoID)
        
        // Extract basic info
        let title = videoInfo["title"] as? String ?? "Bilibili Video"
        let thumbnail = videoInfo["pic"] as? String
        let duration = videoInfo["duration"] as? Double
        
        // Get video cid
        let pageCID = (videoInfo["pages"] as? [[String: Any]])?.first?["cid"] as? Int
        guard let cid = (videoInfo["cid"] as? Int) ?? pageCID else {
            throw ExtractionError.parseError("Could not find video cid")
        }
        
        // Fetch play info with WBI signature
        let playInfo = try await fetchPlayInfo(bvid: videoID, cid: cid)
        
        // Parse formats
        let formats = try parsePlayInfo(playInfo)
        
        guard !formats.isEmpty else {
            throw ExtractionError.noFormatsFound
        }
        
        // Find best format
        let videoFormats = formats.filter { $0.hasVideo }
        let bestFormat = videoFormats.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
            ?? formats.first
        
        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnail,
            duration: duration,
            formats: formats,
            bestFormat: bestFormat
        )
    }
    
    // MARK: - Private Methods
    
    private func resolveShortURL(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              url.host?.contains("b23.tv") == true else {
            return urlString
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        let (_, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse,
           let location = httpResponse.value(forHTTPHeaderField: "Location") {
            return location
        }
        
        return urlString
    }
    
    private func extractVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        
        // BV format
        for component in pathComponents {
            if component.hasPrefix("BV") && component.count >= 10 {
                return component
            }
        }
        
        // AV format
        for component in pathComponents {
            if component.hasPrefix("av"), let avID = Int(component.dropFirst(2)) {
                return "av\(avID)"
            }
        }
        
        return pathComponents.last
    }
    
    private func fetchVideoInfo(videoID: String) async throws -> [String: Any] {
        let apiURL: String
        if videoID.hasPrefix("BV") {
            apiURL = "https://api.bilibili.com/x/web-interface/view?bvid=\(videoID)"
        } else if videoID.hasPrefix("av") {
            let aid = String(videoID.dropFirst(2))
            apiURL = "https://api.bilibili.com/x/web-interface/view?aid=\(aid)"
        } else {
            apiURL = "https://api.bilibili.com/x/web-interface/view?bvid=\(videoID)"
        }
        
        guard let url = URL(string: apiURL) else {
            throw ExtractionError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(
                NSError(domain: "Bilibili", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)
            )
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let videoData = json["data"] as? [String: Any] else {
            throw ExtractionError.parseError("Could not fetch video info")
        }
        
        return videoData
    }
    
    private func fetchPlayInfo(bvid: String, cid: Int) async throws -> [String: Any] {
        // Get WBI key
        let wbiKey = try await getWBIKey()
        
        // Build parameters
        var params: [String: Any] = [
            "bvid": bvid,
            "cid": cid,
            "fnval": 4048,
            "qn": 127
        ]
        
        // Sign with WBI
        let signedParams = signWBI(params: params, wbiKey: wbiKey)
        
        // Build URL
        var components = URLComponents(string: "https://api.bilibili.com/x/player/wbi/playurl")!
        components.queryItems = signedParams.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        
        guard let url = components.url else {
            throw ExtractionError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(
                NSError(domain: "Bilibili", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)
            )
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let playData = json["data"] as? [String: Any] else {
            throw ExtractionError.parseError("Could not fetch play info")
        }
        
        return playData
    }
    
    // MARK: - WBI Signature
    
    private func getWBIKey() async throws -> String {
        // Check cache
        if let wbiKey, Date().timeIntervalSince1970 - wbiKeyTimestamp < wbiKeyCacheTimeout {
            return wbiKey
        }
        
        // Fetch new WBI key
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            throw ExtractionError.invalidURL
        }
        
        let (data, _) = try await session.data(from: url)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let navData = json["data"] as? [String: Any],
              let wbiImg = navData["wbi_img"] as? [String: Any],
              let imgUrl = wbiImg["img_url"] as? String,
              let subUrl = wbiImg["sub_url"] as? String else {
            throw ExtractionError.parseError("Could not fetch WBI key")
        }
        
        // Extract key from URLs
        let imgKey = imgUrl.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
        let subKey = subUrl.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
        let fullKey = imgKey + subKey
        
        // Apply mixin table
        var key = ""
        for index in mixinKeyEncTab {
            if index < fullKey.count {
                let charIndex = fullKey.index(fullKey.startIndex, offsetBy: index)
                key.append(fullKey[charIndex])
            }
        }
        
        let finalKey = String(key.prefix(32))
        
        // Cache
        self.wbiKey = finalKey
        self.wbiKeyTimestamp = Date().timeIntervalSince1970
        
        return finalKey
    }
    
    private func signWBI(params: [String: Any], wbiKey: String) -> [String: Any] {
        var mutableParams = params
        mutableParams["wts"] = Int(Date().timeIntervalSince1970)
        
        // Filter invalid characters and sort
        let filteredParams = mutableParams.mapValues { value -> String in
            let str = "\(value)"
            return str.filter { char in
                !"!'()*".contains(char)
            }
        }
        
        let sortedParams = filteredParams.sorted { $0.key < $1.key }
        let query = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        
        // Calculate MD5
        let signString = query + wbiKey
        let md5 = Insecure.MD5.hash(data: signString.data(using: .utf8) ?? Data())
        let md5Hex = md5.map { String(format: "%02hhx", $0) }.joined()
        
        var result = mutableParams
        result["w_rid"] = md5Hex
        
        return result
    }
    
    // MARK: - Parse Formats
    
    private func parsePlayInfo(_ playInfo: [String: Any]) throws -> [VideoFormat] {
        var formats: [VideoFormat] = []
        
        // Parse DASH format
        if let dash = playInfo["dash"] as? [String: Any] {
            // Video streams
            if let videoStreams = dash["video"] as? [[String: Any]] {
                for (index, stream) in videoStreams.enumerated() {
                    if let format = parseDashStream(stream, type: "video", index: index) {
                        formats.append(format)
                    }
                }
            }
            
            // Audio streams
            if let audioStreams = dash["audio"] as? [[String: Any]] {
                for (index, stream) in audioStreams.enumerated() {
                    if let format = parseDashStream(stream, type: "audio", index: index) {
                        formats.append(format)
                    }
                }
            }
            
            // FLAC audio
            if let flac = dash["flac"] as? [String: Any],
               let audio = flac["audio"] as? [String: Any] {
                if let format = parseDashStream(audio, type: "audio", index: 999) {
                    formats.append(format)
                }
            }
        }
        
        // Parse FLV/MP4 format
        if let durls = playInfo["durl"] as? [[String: Any]] {
            for (index, durl) in durls.enumerated() {
                if let format = parseDurlFormat(durl, index: index) {
                    formats.append(format)
                }
            }
        }
        
        return formats
    }
    
    private func parseDashStream(_ stream: [String: Any], type: String, index: Int) -> VideoFormat? {
        let urlString = (stream["baseUrl"] as? String) ?? (stream["base_url"] as? String) ?? (stream["url"] as? String)
        guard let urlString, let _ = URL(string: urlString) else {
            return nil
        }
        
        let id = stream["id"] as? Int ?? index
        let mimeType = (stream["mimeType"] as? String) ?? (stream["mime_type"] as? String) ?? ""
        let width = stream["width"] as? Int
        let height = stream["height"] as? Int
        let bandwidth = stream["bandwidth"] as? Int64
        let size = stream["size"] as? Int64
        
        let hasVideo = type == "video" || mimeType.contains("video")
        let hasAudio = type == "audio" || mimeType.contains("audio")
        
        var quality = "Unknown"
        if let height {
            quality = "\(height)p"
        } else if let bandwidth {
            quality = "\(bandwidth / 1000)kbps"
        }
        
        return VideoFormat(
            id: "bili-\(type)-\(id)",
            url: urlString,
            quality: quality,
            mimeType: mimeType,
            width: width,
            height: height,
            bitrate: bandwidth,
            fileSize: size,
            fps: stream["frameRate"] as? Double,
            videoCodec: hasVideo ? (stream["codecs"] as? String) : nil,
            audioCodec: hasAudio ? (stream["codecs"] as? String) : nil,
            hasVideo: hasVideo,
            hasAudio: hasAudio
        )
    }
    
    private func parseDurlFormat(_ durl: [String: Any], index: Int) -> VideoFormat? {
        guard let urlString = durl["url"] as? String,
              let _ = URL(string: urlString) else {
            return nil
        }
        
        let size = durl["size"] as? Int64
        let duration = durl["length"] as? Double
        
        return VideoFormat(
            id: "bili-flv-\(index)",
            url: urlString,
            quality: "default",
            mimeType: "video/x-flv",
            width: nil,
            height: nil,
            bitrate: nil,
            fileSize: size,
            fps: nil,
            videoCodec: nil,
            audioCodec: nil,
            hasVideo: true,
            hasAudio: true
        )
    }
}
