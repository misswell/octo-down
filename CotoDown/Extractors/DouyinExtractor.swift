import Foundation

/// Douyin (抖音) video extractor
/// Based on yt-dlp's Douyin extractor
/// Note: Requires cookies (s_v_web_id) for some videos
final class DouyinExtractor: VideoExtractor {
    let platformName = "Douyin"
    
    private let session: URLSession
    
    init() {
        self.session = CookieStore.configuredSession(referer: "https://www.douyin.com/")
    }
    
    func canExtract(url: String) -> Bool {
        guard let url = URL(string: url),
              let host = url.host?.lowercased() else {
            return false
        }
        
        return host.contains("douyin.com") || host.contains("iesdouyin.com")
    }
    
    func extract(url: String) async throws -> ExtractionResult {
        // Resolve short URL if needed
        let resolvedURL = try await resolveShortURL(url)
        
        guard let videoID = extractVideoID(from: resolvedURL) else {
            throw ExtractionError.invalidURL
        }
        
        // Fetch video detail via API
        let detail = try await fetchVideoDetail(videoID: videoID)
        
        // Parse video data
        return try parseAwemeDetail(detail, videoID: videoID)
    }
    
    // MARK: - Private Methods
    
    private func resolveShortURL(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              url.host?.contains("v.douyin.com") == true ||
              url.host?.contains("iesdouyin.com") == true else {
            return urlString
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        CookieStore.apply(to: &request, referer: "https://www.douyin.com/")
        
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
        
        // Standard video URL: /video/1234567890
        if let videoIndex = pathComponents.firstIndex(of: "video"),
           videoIndex + 1 < pathComponents.count {
            return pathComponents[videoIndex + 1]
        }
        
        // Note URL: /note/1234567890
        if let noteIndex = pathComponents.firstIndex(of: "note"),
           noteIndex + 1 < pathComponents.count {
            return pathComponents[noteIndex + 1]
        }
        
        return pathComponents.last
    }
    
    private func fetchVideoDetail(videoID: String) async throws -> [String: Any] {
        // Use Douyin web API
        let apiURL = "https://www.douyin.com/aweme/v1/web/aweme/detail/"
        
        var components = URLComponents(string: apiURL)!
        components.queryItems = [
            URLQueryItem(name: "aweme_id", value: videoID)
        ]
        
        guard let url = components.url else {
            throw ExtractionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        CookieStore.apply(to: &request, referer: "https://www.douyin.com/")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExtractionError.networkError(
                NSError(domain: "Douyin", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: nil)
            )
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractionError.parseError("Could not parse API response")
        }
        
        // Check for errors
        if let statusMsg = json["status_msg"] as? String, !statusMsg.isEmpty {
            throw ExtractionError.parseError("API error: \(statusMsg)")
        }
        
        guard let awemeDetail = json["aweme_detail"] as? [String: Any] else {
            // May need cookies for verification
            if json["aweme_detail"] == nil {
                throw ExtractionError.requiresLogin
            }
            throw ExtractionError.parseError("Could not find aweme detail")
        }
        
        return awemeDetail
    }
    
    private func parseAwemeDetail(_ detail: [String: Any], videoID: String) throws -> ExtractionResult {
        // Extract title
        let title = (detail["desc"] as? String) ?? "Douyin Video"
        
        // Extract thumbnail
        let thumbnail = extractThumbnail(from: detail)
        
        // Extract duration (in milliseconds)
        let durationMs = detail["duration"] as? Int ?? 0
        let duration = Double(durationMs) / 1000.0
        
        // Extract video URL
        var videoURL: String?
        
        // Try video.play_addr
        if let video = detail["video"] as? [String: Any],
           let playAddr = video["play_addr"] as? [String: Any] {
            if let urlList = playAddr["url_list"] as? [String] {
                // Try to get the best quality URL
                videoURL = urlList.first
            } else if let uri = playAddr["uri"] as? String {
                videoURL = "https://www.douyin.com/aweme/v1/play/?video_id=\(uri)"
            }
        }
        
        // Fallback: try play_addr directly
        if videoURL == nil, let playAddr = detail["play_addr"] as? [String: Any],
           let urlList = playAddr["url_list"] as? [String] {
            videoURL = urlList.first
        }
        
        guard let videoURL, let _ = URL(string: videoURL) else {
            throw ExtractionError.noFormatsFound
        }
        
        // Extract video dimensions
        let video = detail["video"] as? [String: Any]
        let width = video?["width"] as? Int
        let height = video?["height"] as? Int
        
        let format = VideoFormat(
            id: "douyin-0",
            url: videoURL,
            quality: height != nil ? "\(height!)p" : "default",
            mimeType: "video/mp4",
            width: width,
            height: height,
            bitrate: nil,
            fileSize: nil,
            fps: nil,
            videoCodec: nil,
            audioCodec: nil,
            hasVideo: true,
            hasAudio: true
        )
        
        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnail,
            duration: duration > 0 ? duration : nil,
            formats: [format],
            bestFormat: format
        )
    }
    
    private func extractThumbnail(from detail: [String: Any]) -> String? {
        // Try video.cover
        if let video = detail["video"] as? [String: Any],
           let cover = video["cover"] as? [String: Any],
           let urlList = cover["url_list"] as? [String] {
            return urlList.first
        }
        
        // Try video.origin_cover
        if let video = detail["video"] as? [String: Any],
           let originCover = video["origin_cover"] as? [String: Any],
           let urlList = originCover["url_list"] as? [String] {
            return urlList.first
        }
        
        // Try share_url
        if let shareUrl = detail["share_url"] as? String {
            return shareUrl
        }
        
        return nil
    }
}
