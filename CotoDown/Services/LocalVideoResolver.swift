import Foundation
import WebKit

/// Errors that can occur during local video resolution
enum LocalResolverError: LocalizedError {
    case invalidURL
    case webViewCreationFailed
    case pageLoadTimeout
    case javascriptExecutionFailed(String)
    case noVideoFormatsFound
    case extractionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid video URL"
        case .webViewCreationFailed:
            "Failed to create web view"
        case .pageLoadTimeout:
            "Page load timeout - please check your internet connection"
        case .javascriptExecutionFailed(let message):
            "JavaScript error: \(message)"
        case .noVideoFormatsFound:
            "No video formats found"
        case .extractionFailed(let message):
            "Extraction failed: \(message)"
        }
    }
}

/// Represents a video format extracted from the page
struct ExtractedVideoFormat: Identifiable, Equatable {
    let id: String
    let url: String
    let quality: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let bitrate: Int64?
    let fileSize: Int64?
    
    var displayQuality: String {
        if let height {
            return "\(height)p"
        }
        return quality
    }
}

/// Result of video extraction
struct LocalVideoInfo: Equatable {
    let title: String
    let thumbnailURL: String?
    let duration: Double?
    let formats: [ExtractedVideoFormat]
    let bestFormat: ExtractedVideoFormat?
}

/// Service to resolve video URLs locally using WKWebView
@MainActor
final class LocalVideoResolver: NSObject, ObservableObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<LocalVideoInfo, Error>?
    private var timeoutTask: Task<Void, Never>?
    
    /// Check if a URL can be resolved locally
    static func canResolve(_ urlString: String) -> Bool {
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
    
    /// Resolve video information from URL
    func resolve(url: String) async throws -> LocalVideoInfo {
        guard URL(string: url) != nil else {
            throw LocalResolverError.invalidURL
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            
            // Create web view
            setupWebView()
            
            // Start timeout (longer for Chinese platforms which may be slower)
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000) // 45 seconds
                if self.continuation != nil {
                    self.continuation?.resume(throwing: LocalResolverError.pageLoadTimeout)
                    self.continuation = nil
                    self.cleanup()
                }
            }
            
            // Load URL
            if let request = URLRequest(url: URL(string: url)!) as URLRequest? {
                webView?.load(request)
            }
        }
    }
    
    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        
        // Add JavaScript message handler
        let contentController = WKUserContentController()
        contentController.add(self, name: "videoExtractor")
        configuration.userContentController = contentController
        
        // Create web view
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isHidden = true
        self.webView = webView
        
        // Add to view hierarchy (required for web view to work)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.addSubview(webView)
        }
    }
    
    private func cleanup() {
        timeoutTask?.cancel()
        webView?.removeFromSuperview()
        webView = nil
    }
}

// MARK: - WKNavigationDelegate
extension LocalVideoResolver: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded, now inject JavaScript to extract video info
        injectExtractionScript()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: LocalResolverError.extractionFailed(error.localizedDescription))
        continuation = nil
        cleanup()
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: LocalResolverError.extractionFailed(error.localizedDescription))
        continuation = nil
        cleanup()
    }
    
    private func injectExtractionScript() {
        let script = """
        (function() {
            try {
                var videoInfo = null;
                var hostname = window.location.hostname.toLowerCase();
                
                // Detect platform and use appropriate extractor
                if (hostname.includes('youtube.com') || hostname.includes('youtu.be')) {
                    videoInfo = extractYouTube();
                } else if (hostname.includes('bilibili.com') || hostname.includes('b23.tv')) {
                    videoInfo = extractBilibili();
                } else if (hostname.includes('douyin.com')) {
                    videoInfo = extractDouyin();
                } else if (hostname.includes('xiaohongshu.com') || hostname.includes('xhslink.com')) {
                    videoInfo = extractXiaohongshu();
                } else if (hostname.includes('vimeo.com')) {
                    videoInfo = extractVimeo();
                } else if (hostname.includes('tiktok.com')) {
                    videoInfo = extractTikTok();
                } else if (hostname.includes('twitter.com') || hostname.includes('x.com')) {
                    videoInfo = extractTwitter();
                } else if (hostname.includes('instagram.com')) {
                    videoInfo = extractInstagram();
                } else if (hostname.includes('dailymotion.com')) {
                    videoInfo = extractDailymotion();
                }
                
                if (videoInfo && videoInfo.formats && videoInfo.formats.length > 0) {
                    window.webkit.messageHandlers.videoExtractor.postMessage({
                        success: true,
                        data: videoInfo
                    });
                } else {
                    window.webkit.messageHandlers.videoExtractor.postMessage({
                        success: false,
                        error: 'Could not find video data for this platform'
                    });
                }
            } catch (e) {
                window.webkit.messageHandlers.videoExtractor.postMessage({
                    success: false,
                    error: e.toString()
                });
            }
            
            // ==================== YouTube ====================
            function extractYouTube() {
                try {
                    var videoInfo = null;
                    
                    // Try ytInitialPlayerResponse
                    if (typeof ytInitialPlayerResponse !== 'undefined') {
                        videoInfo = parseYouTubeData(ytInitialPlayerResponse);
                    }
                    
                    // Try window.ytplayer
                    if (!videoInfo && typeof window.ytplayer !== 'undefined') {
                        videoInfo = parseYouTubeData(window.ytplayer);
                    }
                    
                    // Try to find script tags
                    if (!videoInfo) {
                        var scripts = document.querySelectorAll('script');
                        for (var i = 0; i < scripts.length; i++) {
                            var text = scripts[i].textContent;
                            if (text.includes('ytInitialPlayerResponse')) {
                                var match = text.match(/ytInitialPlayerResponse\\s*=\\s*({.*?});/s);
                                if (match) {
                                    try {
                                        var data = JSON.parse(match[1]);
                                        videoInfo = parseYouTubeData(data);
                                        if (videoInfo) break;
                                    } catch (e) {}
                                }
                            }
                        }
                    }
                    
                    return videoInfo;
                } catch (e) {
                    return null;
                }
            }
            
            function parseYouTubeData(data) {
                try {
                    var videoDetails = data.videoDetails || {};
                    var streamingData = data.streamingData || {};
                    
                    var title = videoDetails.title || document.title || 'Untitled';
                    var thumbnail = videoDetails.thumbnail?.thumbnails?.pop()?.url || null;
                    var duration = parseFloat(videoDetails.lengthSeconds) || null;
                    
                    var formats = [];
                    
                    if (streamingData.formats) {
                        streamingData.formats.forEach(function(f) {
                            if (f.url) {
                                formats.push({
                                    id: f.itag?.toString() || formats.length.toString(),
                                    url: f.url,
                                    quality: f.qualityLabel || f.quality || 'Unknown',
                                    mimeType: f.mimeType || '',
                                    width: f.width || null,
                                    height: f.height || null,
                                    bitrate: f.bitrate || null,
                                    fileSize: f.contentLength ? parseInt(f.contentLength) : null
                                });
                            }
                        });
                    }
                    
                    if (streamingData.adaptiveFormats) {
                        streamingData.adaptiveFormats.forEach(function(f) {
                            if (f.url) {
                                formats.push({
                                    id: f.itag?.toString() || formats.length.toString(),
                                    url: f.url,
                                    quality: f.qualityLabel || f.quality || 'Unknown',
                                    mimeType: f.mimeType || '',
                                    width: f.width || null,
                                    height: f.height || null,
                                    bitrate: f.bitrate || null,
                                    fileSize: f.contentLength ? parseInt(f.contentLength) : null
                                });
                            }
                        });
                    }
                    
                    if (formats.length === 0) return null;
                    
                    var bestFormat = formats.reduce(function(best, f) {
                        if (!best) return f;
                        if ((f.height || 0) > (best.height || 0)) return f;
                        return best;
                    }, null);
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: bestFormat
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== Bilibili ====================
            function extractBilibili() {
                try {
                    var title = document.title.replace('_哔哩哔哩_bilibili', '').replace('- 哔哩哔哩', '').trim();
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try __playinfo__ (standard Bilibili)
                    if (typeof window.__playinfo__ !== 'undefined') {
                        var playinfo = window.__playinfo__;
                        var data = playinfo.data || playinfo;
                        
                        // Get video streams
                        var dash = data.dash;
                        if (dash) {
                            // DASH format - separate video and audio
                            if (dash.video) {
                                dash.video.forEach(function(v, idx) {
                                    if (v.baseUrl || v.base_url) {
                                        formats.push({
                                            id: 'bili-video-' + idx,
                                            url: v.baseUrl || v.base_url,
                                            quality: v.id?.toString() || 'Unknown',
                                            mimeType: v.mimeType || v.mime_type || 'video/mp4',
                                            width: v.width || null,
                                            height: v.height || null,
                                            bitrate: v.bandwidth || null,
                                            fileSize: null
                                        });
                                    }
                                });
                            }
                            if (dash.audio) {
                                dash.audio.forEach(function(a, idx) {
                                    if (a.baseUrl || a.base_url) {
                                        formats.push({
                                            id: 'bili-audio-' + idx,
                                            url: a.baseUrl || a.base_url,
                                            quality: 'audio-' + (a.id || idx),
                                            mimeType: a.mimeType || a.mime_type || 'audio/mp4',
                                            width: null,
                                            height: null,
                                            bitrate: a.bandwidth || null,
                                            fileSize: null
                                        });
                                    }
                                });
                            }
                        }
                        
                        // FLV format
                        var durl = data.durl;
                        if (durl && durl.length > 0) {
                            durl.forEach(function(d, idx) {
                                if (d.url) {
                                    formats.push({
                                        id: 'bili-flv-' + idx,
                                        url: d.url,
                                        quality: 'flv-' + idx,
                                        mimeType: 'video/x-flv',
                                        width: null,
                                        height: null,
                                        bitrate: null,
                                        fileSize: d.size || null
                                    });
                                }
                            });
                        }
                    }
                    
                    // Try to find thumbnail from meta tags
                    var ogImage = document.querySelector('meta[property="og:image"]');
                    if (ogImage) {
                        thumbnail = ogImage.content;
                    }
                    
                    // Try to get duration from player
                    var durationEl = document.querySelector('.bpx-player-ctrl-time-duration');
                    if (durationEl) {
                        var parts = durationEl.textContent.split(':').map(Number);
                        if (parts.length === 2) {
                            duration = parts[0] * 60 + parts[1];
                        } else if (parts.length === 3) {
                            duration = parts[0] * 3600 + parts[1] * 60 + parts[2];
                        }
                    }
                    
                    if (formats.length === 0) return null;
                    
                    // For Bilibili, prefer video+audio combined or highest quality
                    var bestFormat = formats.reduce(function(best, f) {
                        if (!best) return f;
                        // Prefer video formats over audio-only
                        if (f.mimeType.startsWith('video') && !best.mimeType.startsWith('video')) return f;
                        if ((f.height || 0) > (best.height || 0)) return f;
                        return best;
                    }, null);
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: bestFormat
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== Douyin ====================
            function extractDouyin() {
                try {
                    var title = document.title.replace(' - 抖音', '').replace(' - 抖音搜索', '').trim();
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try RENDER_DATA
                    var renderDataEl = document.getElementById('RENDER_DATA');
                    if (renderDataEl) {
                        try {
                            var renderData = JSON.parse(decodeURIComponent(renderDataEl.textContent));
                            
                            // Navigate through the data structure to find video info
                            var videoData = findVideoInObject(renderData);
                            if (videoData) {
                                if (videoData.title) title = videoData.title;
                                if (videoData.cover) thumbnail = videoData.cover;
                                if (videoData.duration) duration = videoData.duration / 1000;
                                
                                // Get video URLs
                                if (videoData.playAddr) {
                                    var playAddr = videoData.playAddr;
                                    if (typeof playAddr === 'string') {
                                        formats.push({
                                            id: 'douyin-0',
                                            url: playAddr,
                                            quality: 'default',
                                            mimeType: 'video/mp4',
                                            width: videoData.width || null,
                                            height: videoData.height || null,
                                            bitrate: null,
                                            fileSize: null
                                        });
                                    } else if (Array.isArray(playAddr)) {
                                        playAddr.forEach(function(addr, idx) {
                                            if (addr.src || addr.url) {
                                                formats.push({
                                                    id: 'douyin-' + idx,
                                                    url: addr.src || addr.url,
                                                    quality: addr.quality || 'variant-' + idx,
                                                    mimeType: 'video/mp4',
                                                    width: videoData.width || null,
                                                    height: videoData.height || null,
                                                    bitrate: null,
                                                    fileSize: null
                                                });
                                            }
                                        });
                                    }
                                }
                                
                                // Try video.playApi
                                if (videoData.playApi) {
                                    formats.push({
                                        id: 'douyin-api',
                                        url: videoData.playApi,
                                        quality: 'api',
                                        mimeType: 'video/mp4',
                                        width: null,
                                        height: null,
                                        bitrate: null,
                                        fileSize: null
                                    });
                                }
                            }
                        } catch (e) {}
                    }
                    
                    // Try to find video element
                    if (formats.length === 0) {
                        var videoEl = document.querySelector('video');
                        if (videoEl && videoEl.src) {
                            formats.push({
                                id: 'douyin-video-el',
                                url: videoEl.src,
                                quality: 'default',
                                mimeType: 'video/mp4',
                                width: videoEl.videoWidth || null,
                                height: videoEl.videoHeight || null,
                                bitrate: null,
                                fileSize: null
                            });
                        }
                    }
                    
                    // Try meta tags
                    if (!thumbnail) {
                        var ogImage = document.querySelector('meta[property="og:image"]');
                        if (ogImage) thumbnail = ogImage.content;
                    }
                    
                    if (formats.length === 0) return null;
                    
                    var bestFormat = formats[0];
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: bestFormat
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // Helper to find video data in nested objects
            function findVideoInObject(obj, depth) {
                if (depth > 10) return null;
                if (!obj || typeof obj !== 'object') return null;
                
                // Check if this object has video-like properties
                if (obj.playAddr || obj.play_addr || obj.playApi || obj.play_api) {
                    return obj;
                }
                
                // Search recursively
                for (var key in obj) {
                    if (obj.hasOwnProperty(key)) {
                        var result = findVideoInObject(obj[key], (depth || 0) + 1);
                        if (result) return result;
                    }
                }
                
                return null;
            }
            
            // ==================== Xiaohongshu ====================
            function extractXiaohongshu() {
                try {
                    var title = document.title.replace(' - 小红书', '').trim();
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try __INITIAL_STATE__
                    if (typeof window.__INITIAL_STATE__ !== 'undefined') {
                        var state = window.__INITIAL_STATE__;
                        
                        // Navigate to note data
                        var noteData = state.note || state.noteDetailMap || state.noteData;
                        if (noteData) {
                            // Get the first note
                            var note = null;
                            if (noteData.currentNoteId && noteData.noteDetailMap) {
                                note = noteData.noteDetailMap[noteData.currentNoteId];
                            } else if (noteData.note) {
                                note = noteData.note;
                            } else {
                                // Try to get first available note
                                for (var key in noteData) {
                                    if (noteData[key] && typeof noteData[key] === 'object') {
                                        note = noteData[key];
                                        break;
                                    }
                                }
                            }
                            
                            if (note) {
                                if (note.title) title = note.title;
                                if (note.cover) thumbnail = note.cover;
                                
                                // Get video URL
                                var video = note.video || note.videoMedia;
                                if (video) {
                                    if (video.url) {
                                        formats.push({
                                            id: 'xhs-0',
                                            url: video.url,
                                            quality: 'default',
                                            mimeType: 'video/mp4',
                                            width: video.width || null,
                                            height: video.height || null,
                                            bitrate: null,
                                            fileSize: null
                                        });
                                    }
                                    
                                    // Try streaming URL
                                    if (video.streaming) {
                                        var streaming = video.streaming;
                                        if (streaming.h264) {
                                            streaming.h264.forEach(function(s, idx) {
                                                if (s.masterUrl || s.master_url) {
                                                    formats.push({
                                                        id: 'xhs-h264-' + idx,
                                                        url: s.masterUrl || s.master_url,
                                                        quality: s.quality || 'h264-' + idx,
                                                        mimeType: 'video/mp4',
                                                        width: s.width || null,
                                                        height: s.height || null,
                                                        bitrate: s.bitrate || null,
                                                        fileSize: null
                                                    });
                                                }
                                            });
                                        }
                                        if (streaming.h265) {
                                            streaming.h265.forEach(function(s, idx) {
                                                if (s.masterUrl || s.master_url) {
                                                    formats.push({
                                                        id: 'xhs-h265-' + idx,
                                                        url: s.masterUrl || s.master_url,
                                                        quality: s.quality || 'h265-' + idx,
                                                        mimeType: 'video/mp4',
                                                        width: s.width || null,
                                                        height: s.height || null,
                                                        bitrate: s.bitrate || null,
                                                        fileSize: null
                                                    });
                                                }
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // Try to find video element
                    if (formats.length === 0) {
                        var videoEl = document.querySelector('video source, video');
                        if (videoEl) {
                            var videoSrc = videoEl.src || videoEl.querySelector('source')?.src;
                            if (videoSrc) {
                                formats.push({
                                    id: 'xhs-video-el',
                                    url: videoSrc,
                                    quality: 'default',
                                    mimeType: 'video/mp4',
                                    width: videoEl.videoWidth || null,
                                    height: videoEl.videoHeight || null,
                                    bitrate: null,
                                    fileSize: null
                                });
                            }
                        }
                    }
                    
                    // Try meta tags
                    if (!thumbnail) {
                        var ogImage = document.querySelector('meta[property="og:image"]');
                        if (ogImage) thumbnail = ogImage.content;
                    }
                    
                    if (formats.length === 0) return null;
                    
                    var bestFormat = formats.reduce(function(best, f) {
                        if (!best) return f;
                        if ((f.height || 0) > (best.height || 0)) return f;
                        return best;
                    }, null);
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: bestFormat
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== Vimeo ====================
            function extractVimeo() {
                try {
                    var title = document.title;
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try window.playerConfig
                    if (typeof window.playerConfig !== 'undefined') {
                        var config = window.playerConfig;
                        if (config.video) {
                            title = config.video.title || title;
                            thumbnail = config.video.thumbs?.base || thumbnail;
                            duration = config.video.duration || duration;
                        }
                        if (config.request?.files) {
                            var files = config.request.files;
                            if (files.progressive) {
                                files.progressive.forEach(function(f, idx) {
                                    formats.push({
                                        id: 'vimeo-' + idx,
                                        url: f.url,
                                        quality: f.quality || f.height + 'p',
                                        mimeType: 'video/mp4',
                                        width: f.width || null,
                                        height: f.height || null,
                                        bitrate: null,
                                        fileSize: null
                                    });
                                });
                            }
                        }
                    }
                    
                    // Try vimeo.clip_page_config
                    if (formats.length === 0 && typeof window.vimeo !== 'undefined') {
                        // Alternative extraction
                    }
                    
                    if (formats.length === 0) return null;
                    
                    var bestFormat = formats.reduce(function(best, f) {
                        if (!best) return f;
                        if ((f.height || 0) > (best.height || 0)) return f;
                        return best;
                    }, null);
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: bestFormat
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== TikTok ====================
            function extractTikTok() {
                try {
                    var title = document.title;
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try SIGI_STATE
                    var sigiState = document.getElementById('SIGI_STATE');
                    if (sigiState) {
                        try {
                            var state = JSON.parse(sigiState.textContent);
                            var itemModule = state.ItemModule || {};
                            var items = Object.values(itemModule);
                            if (items.length > 0) {
                                var item = items[0];
                                title = item.desc || title;
                                thumbnail = item.cover || thumbnail;
                                
                                if (item.video) {
                                    var video = item.video;
                                    if (video.playAddr) {
                                        formats.push({
                                            id: 'tiktok-0',
                                            url: video.playAddr,
                                            quality: 'default',
                                            mimeType: 'video/mp4',
                                            width: video.width || null,
                                            height: video.height || null,
                                            bitrate: null,
                                            fileSize: null
                                        });
                                    }
                                }
                            }
                        } catch (e) {}
                    }
                    
                    // Try RENDER_DATA
                    if (formats.length === 0) {
                        var renderData = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
                        if (renderData) {
                            try {
                                var data = JSON.parse(renderData.textContent);
                                // Navigate through data to find video
                                var videoData = findVideoInObject(data, 0);
                                if (videoData && videoData.playAddr) {
                                    formats.push({
                                        id: 'tiktok-re-0',
                                        url: videoData.playAddr,
                                        quality: 'default',
                                        mimeType: 'video/mp4',
                                        width: videoData.width || null,
                                        height: videoData.height || null,
                                        bitrate: null,
                                        fileSize: null
                                    });
                                }
                            } catch (e) {}
                        }
                    }
                    
                    if (formats.length === 0) return null;
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: formats[0]
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== Twitter/X ====================
            function extractTwitter() {
                try {
                    var title = document.title;
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try to find video in page data
                    var scripts = document.querySelectorAll('script');
                    for (var i = 0; i < scripts.length; i++) {
                        var text = scripts[i].textContent;
                        if (text.includes('video_url') || text.includes('playbackUrl')) {
                            var urlMatch = text.match(/"video_url"\\s*:\\s*"([^"]+)"/);
                            if (!urlMatch) {
                                urlMatch = text.match(/"playbackUrl"\\s*:\\s*"([^"]+)"/);
                            }
                            if (urlMatch) {
                                formats.push({
                                    id: 'twitter-0',
                                    url: urlMatch[1].replace(/\\\\u002F/g, '/'),
                                    quality: 'default',
                                    mimeType: 'video/mp4',
                                    width: null,
                                    height: null,
                                    bitrate: null,
                                    fileSize: null
                                });
                            }
                        }
                    }
                    
                    // Try video element
                    if (formats.length === 0) {
                        var videoEl = document.querySelector('video');
                        if (videoEl && videoEl.src) {
                            formats.push({
                                id: 'twitter-video',
                                url: videoEl.src,
                                quality: 'default',
                                mimeType: 'video/mp4',
                                width: videoEl.videoWidth || null,
                                height: videoEl.videoHeight || null,
                                bitrate: null,
                                fileSize: null
                            });
                        }
                    }
                    
                    if (formats.length === 0) return null;
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: formats[0]
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== Instagram ====================
            function extractInstagram() {
                try {
                    var title = document.title;
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try to find video URL in page source
                    var scripts = document.querySelectorAll('script[type="application/ld+json"]');
                    for (var i = 0; i < scripts.length; i++) {
                        try {
                            var data = JSON.parse(scripts[i].textContent);
                            if (data.video && data.video.contentUrl) {
                                formats.push({
                                    id: 'instagram-ld',
                                    url: data.video.contentUrl,
                                    quality: 'default',
                                    mimeType: 'video/mp4',
                                    width: null,
                                    height: null,
                                    bitrate: null,
                                    fileSize: null
                                });
                            }
                        } catch (e) {}
                    }
                    
                    // Try meta tags
                    if (formats.length === 0) {
                        var ogVideo = document.querySelector('meta[property="og:video"]');
                        if (ogVideo && ogVideo.content) {
                            formats.push({
                                id: 'instagram-og',
                                url: ogVideo.content,
                                quality: 'default',
                                mimeType: 'video/mp4',
                                width: null,
                                height: null,
                                bitrate: null,
                                fileSize: null
                            });
                        }
                    }
                    
                    // Try video element
                    if (formats.length === 0) {
                        var videoEl = document.querySelector('video');
                        if (videoEl && videoEl.src) {
                            formats.push({
                                id: 'instagram-video',
                                url: videoEl.src,
                                quality: 'default',
                                mimeType: 'video/mp4',
                                width: videoEl.videoWidth || null,
                                height: videoEl.videoHeight || null,
                                bitrate: null,
                                fileSize: null
                            });
                        }
                    }
                    
                    if (formats.length === 0) return null;
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: formats[0]
                    };
                } catch (e) {
                    return null;
                }
            }
            
            // ==================== Dailymotion ====================
            function extractDailymotion() {
                try {
                    var title = document.title;
                    var thumbnail = null;
                    var duration = null;
                    var formats = [];
                    
                    // Try window.__PLAYER_CONFIG__
                    if (typeof window.__PLAYER_CONFIG__ !== 'undefined') {
                        var config = window.__PLAYER_CONFIG__;
                        if (config.metadata) {
                            title = config.metadata.title || title;
                            thumbnail = config.metadata.poster?.url || thumbnail;
                            duration = config.metadata.duration || duration;
                        }
                        if (config.qualities) {
                            var qualities = config.qualities;
                            for (var q in qualities) {
                                if (qualities[q]) {
                                    qualities[q].forEach(function(item, idx) {
                                        if (item.url) {
                                            formats.push({
                                                id: 'dm-' + q + '-' + idx,
                                                url: item.url,
                                                quality: q + 'p',
                                                mimeType: item.type || 'video/mp4',
                                                width: null,
                                                height: parseInt(q) || null,
                                                bitrate: null,
                                                fileSize: null
                                            });
                                        }
                                    });
                                }
                            }
                        }
                    }
                    
                    if (formats.length === 0) return null;
                    
                    var bestFormat = formats.reduce(function(best, f) {
                        if (!best) return f;
                        if ((f.height || 0) > (best.height || 0)) return f;
                        return best;
                    }, null);
                    
                    return {
                        title: title,
                        thumbnailURL: thumbnail,
                        duration: duration,
                        formats: formats,
                        bestFormat: bestFormat
                    };
                } catch (e) {
                    return null;
                }
            }
        })();
        """
        
        webView?.evaluateJavaScript(script) { result, error in
            if let error {
                self.continuation?.resume(throwing: LocalResolverError.javascriptExecutionFailed(error.localizedDescription))
                self.continuation = nil
                self.cleanup()
            }
        }
    }
}

// MARK: - WKScriptMessageHandler
extension LocalVideoResolver: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "videoExtractor",
              let body = message.body as? [String: Any] else {
            return
        }
        
        let success = body["success"] as? Bool ?? false
        
        if success, let data = body["data"] as? [String: Any] {
            // Parse the video info
            let title = data["title"] as? String ?? "Untitled"
            let thumbnailURL = data["thumbnailURL"] as? String
            let duration = data["duration"] as? Double
            
            var formats: [ExtractedVideoFormat] = []
            if let formatsData = data["formats"] as? [[String: Any]] {
                formats = formatsData.compactMap { formatData in
                    guard let id = formatData["id"] as? String,
                          let url = formatData["url"] as? String else {
                        return nil
                    }
                    
                    return ExtractedVideoFormat(
                        id: id,
                        url: url,
                        quality: formatData["quality"] as? String ?? "Unknown",
                        mimeType: formatData["mimeType"] as? String ?? "",
                        width: formatData["width"] as? Int,
                        height: formatData["height"] as? Int,
                        bitrate: formatData["bitrate"] as? Int64,
                        fileSize: formatData["fileSize"] as? Int64
                    )
                }
            }
            
            let bestFormat: ExtractedVideoFormat?
            if let bestData = data["bestFormat"] as? [String: Any],
               let bestId = bestData["id"] as? String,
               let bestUrl = bestData["url"] as? String {
                bestFormat = ExtractedVideoFormat(
                    id: bestId,
                    url: bestUrl,
                    quality: bestData["quality"] as? String ?? "Unknown",
                    mimeType: bestData["mimeType"] as? String ?? "",
                    width: bestData["width"] as? Int,
                    height: bestData["height"] as? Int,
                    bitrate: bestData["bitrate"] as? Int64,
                    fileSize: bestData["fileSize"] as? Int64
                )
            } else {
                bestFormat = formats.first
            }
            
            let videoInfo = LocalVideoInfo(
                title: title,
                thumbnailURL: thumbnailURL,
                duration: duration,
                formats: formats,
                bestFormat: bestFormat
            )
            
            continuation?.resume(returning: videoInfo)
            continuation = nil
            cleanup()
            
        } else {
            let error = body["error"] as? String ?? "Unknown error"
            continuation?.resume(throwing: LocalResolverError.extractionFailed(error))
            continuation = nil
            cleanup()
        }
    }
}
