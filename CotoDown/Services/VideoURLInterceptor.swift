import Foundation
import WebKit

/// Intercepts video URLs from web pages using WKWebView
/// This approach works by loading the page in a web view and intercepting
/// network requests to capture the actual video stream URLs
@MainActor
final class VideoURLInterceptor: NSObject, ObservableObject {
    private var webView: WKWebView?
    private var interceptedURLs: [String] = []
    private var continuation: CheckedContinuation<[String], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var hasFoundVideo = false
    
    /// Check if a URL might contain video content
    static func canIntercept(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }
        
        let supportedHosts = [
            // International platforms
            "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
            "vimeo.com", "www.vimeo.com",
            "dailymotion.com", "www.dailymotion.com",
            "tiktok.com", "www.tiktok.com",
            "twitter.com", "www.twitter.com", "x.com", "www.x.com",
            "instagram.com", "www.instagram.com",
            
            // Chinese platforms
            "bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv",
            "douyin.com", "www.douyin.com",
            "xiaohongshu.com", "www.xiaohongshu.com", "xhslink.com"
        ]
        
        return supportedHosts.contains(host)
    }
    
    /// Intercept video URLs from a webpage
    /// - Parameters:
    ///   - url: The webpage URL
    ///   - timeout: Timeout in seconds (default 30)
    /// - Returns: Array of intercepted video URLs
    func interceptVideoURLs(from url: String, timeout: TimeInterval = 30) async throws -> [String] {
        guard URL(string: url) != nil else {
            throw VideoInterceptorError.invalidURL
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.interceptedURLs = []
            self.hasFoundVideo = false
            
            // Setup web view with content controller to intercept requests
            setupWebView()
            
            // Start timeout
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self.continuation != nil {
                    // Return whatever URLs we found, even if none
                    self.continuation?.resume(returning: self.interceptedURLs)
                    self.continuation = nil
                    self.cleanup()
                }
            }
            
            // Load the URL
            if let requestURL = URL(string: url) {
                let request = URLRequest(url: requestURL)
                webView?.load(request)
            }
        }
    }
    
    private func setupWebView() {
        // Create configuration with content controller
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        // Add script message handler to detect video elements
        let contentController = WKUserContentController()
        contentController.add(self, name: "videoDetector")
        configuration.userContentController = contentController
        
        // Create web view
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.isHidden = true
        self.webView = webView
        
        // Set custom URL scheme handler to intercept requests
        // Note: We'll use WKNavigationDelegate methods instead
        
        // Add to view hierarchy
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.addSubview(webView)
        }
    }
    
    private func cleanup() {
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }
    
    private func isVideoURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        let videoExtensions = ["mp4", "m3u8", "mpd", "webm", "mov", "avi", "flv", "mkv"]
        
        // Check file extension
        if videoExtensions.contains(pathExtension) {
            return true
        }
        
        // Check URL patterns for known video CDNs
        let urlString = url.absoluteString.lowercased()
        let videoPatterns = [
            "googlevideo.com",
            "video.google.com",
            "ytimg.com",
            "bilivideo.com",
            "bilibili.com/video",
            "douyinvod.com",
            "snssdk.com",
            "xhscdn.com",
            "xiaohongshu.com/video",
            "vimeo.com/video",
            "dailymotion.com/video",
            "cdninstagram.com",
            "video.twimg.com"
        ]
        
        for pattern in videoPatterns {
            if urlString.contains(pattern) {
                return true
            }
        }
        
        // Check for video content type hints in URL
        if urlString.contains("video") || urlString.contains("media") || urlString.contains("stream") {
            // Additional check for common video parameters
            if urlString.contains("mime=video") || urlString.contains("type=video") {
                return true
            }
        }
        
        return false
    }
    
    private func foundVideoURL(_ url: String) {
        guard !interceptedURLs.contains(url) else { return }
        interceptedURLs.append(url)
        
        // If we found a video URL, we can return early
        if !hasFoundVideo {
            hasFoundVideo = true
            // Wait a bit more to collect more URLs, then return
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                if self.continuation != nil {
                    self.continuation?.resume(returning: self.interceptedURLs)
                    self.continuation = nil
                    self.cleanup()
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate
extension VideoURLInterceptor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Allow all navigation
        return .allow
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Check if this response contains video content
        if let response = navigationResponse.response as? HTTPURLResponse,
           let url = response.url {
            
            // Check content type
            if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
                if contentType.contains("video/") {
                    foundVideoURL(url.absoluteString)
                }
            }
            
            // Check URL patterns
            if isVideoURL(url) {
                foundVideoURL(url.absoluteString)
            }
        }
        
        return .allow
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded, inject script to find video elements and trigger playback
        injectVideoDetectionScript()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Navigation failed, return whatever we found
        if self.continuation != nil {
            self.continuation?.resume(returning: self.interceptedURLs)
            self.continuation = nil
            self.cleanup()
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.continuation != nil {
            self.continuation?.resume(returning: self.interceptedURLs)
            self.continuation = nil
            self.cleanup()
        }
    }
    
    private func injectVideoDetectionScript() {
        let script = """
        (function() {
            // Find all video and source elements
            var videos = document.querySelectorAll('video');
            var sources = document.querySelectorAll('source');
            
            var videoURLs = [];
            
            // Collect URLs from video elements
            videos.forEach(function(video) {
                if (video.src) videoURLs.push(video.src);
                if (video.currentSrc) videoURLs.push(video.currentSrc);
                
                // Check source children
                var videoSources = video.querySelectorAll('source');
                videoSources.forEach(function(source) {
                    if (source.src) videoURLs.push(source.src);
                });
            });
            
            // Collect URLs from standalone source elements
            sources.forEach(function(source) {
                if (source.src) videoURLs.push(source.src);
            });
            
            // Try to find video URLs in page scripts
            var scripts = document.querySelectorAll('script');
            scripts.forEach(function(script) {
                var text = script.textContent;
                // Look for common video URL patterns
                var matches = text.match(/https?:\\/\\/[^"'\\s]+\\.(?:mp4|m3u8|mpd|webm)[^"'\\s]*/gi);
                if (matches) {
                    videoURLs = videoURLs.concat(matches);
                }
            });
            
            // Report found URLs
            if (videoURLs.length > 0) {
                window.webkit.messageHandlers.videoDetector.postMessage({
                    type: 'videoURLs',
                    urls: videoURLs
                });
            }
            
            // Try to auto-play videos to trigger network requests
            videos.forEach(function(video) {
                video.play().catch(function() {});
            });
        })();
        """
        
        webView?.evaluateJavaScript(script) { _, _ in }
    }
}

// MARK: - WKScriptMessageHandler
extension VideoURLInterceptor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "videoDetector",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "videoURLs",
              let urls = body["urls"] as? [String] else {
            return
        }
        
        for url in urls {
            foundVideoURL(url)
        }
    }
}

// MARK: - Error Types
enum VideoInterceptorError: LocalizedError {
    case invalidURL
    case noVideoFound
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .noVideoFound:
            "No video found on this page"
        case .timeout:
            "Timeout while loading page"
        }
    }
}
