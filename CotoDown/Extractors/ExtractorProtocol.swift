import Foundation

/// Protocol for video extractors
protocol VideoExtractor {
    /// Platform name
    var platformName: String { get }
    
    /// Supported URL patterns
    func canExtract(url: String) -> Bool
    
    /// Extract video info from URL
    func extract(url: String) async throws -> ExtractionResult
}

/// Result of video extraction
struct ExtractionResult: Equatable {
    let title: String
    let thumbnailURL: String?
    let duration: Double?
    let formats: [VideoFormat]
    let bestFormat: VideoFormat?
}

/// Video format information
struct VideoFormat: Identifiable, Equatable {
    let id: String
    let url: String
    let quality: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let bitrate: Int64?
    let fileSize: Int64?
    let fps: Double?
    let videoCodec: String?
    let audioCodec: String?
    let hasVideo: Bool
    let hasAudio: Bool
    
    var displayQuality: String {
        if let height {
            return "\(height)p"
        }
        return quality
    }
}

/// Extraction errors
enum ExtractionError: LocalizedError {
    case unsupportedPlatform
    case invalidURL
    case networkError(Error)
    case parseError(String)
    case noFormatsFound
    case rateLimited
    case requiresLogin
    case geoBlocked
    
    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "This platform is not supported"
        case .invalidURL:
            "Invalid URL"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            "Parse error: \(message)"
        case .noFormatsFound:
            "No video formats found"
        case .rateLimited:
            "Rate limited - please wait and try again"
        case .requiresLogin:
            "This video requires login"
        case .geoBlocked:
            "This video is not available in your region"
        }
    }
}
