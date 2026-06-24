import Foundation

/// Manages all video extractors
@MainActor
final class ExtractorManager: ObservableObject {
    static let shared = ExtractorManager()
    
    private let extractors: [VideoExtractor] = [
        YouTubeExtractor(),
        BilibiliExtractor(),
        DouyinExtractor(),
        XiaohongshuExtractor(),
    ]
    
    /// Find the appropriate extractor for a URL
    func extractor(for url: String) -> VideoExtractor? {
        return extractors.first { $0.canExtract(url: url) }
    }
    
    /// Check if a URL can be extracted
    func canExtract(url: String) -> Bool {
        return extractor(for: url) != nil
    }
    
    /// Extract video info from URL
    func extract(url: String) async throws -> ExtractionResult {
        guard let extractor = extractor(for: url) else {
            throw ExtractionError.unsupportedPlatform
        }
        
        return try await extractor.extract(url: url)
    }
    
    /// Get all supported platforms
    var supportedPlatforms: [String] {
        return extractors.map { $0.platformName }
    }
}
