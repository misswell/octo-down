import Foundation

/// Unified video resolver that tries native extractors first, then falls back to URL interception, then external resolver
@MainActor
final class VideoResolverService: ObservableObject {
    private let extractorManager = ExtractorManager.shared
    private let interceptor = VideoURLInterceptor()
    private let externalResolver = BackendResolver()
    
    /// Resolve video info
    func resolveInfo(
        url: String,
        template: DownloadTemplate,
        argumentOverride: String?,
        endpoint: String,
        token: String
    ) async throws -> ResolvedLinkInfo {
        // Strategy 1: Try native extractor (fastest, most reliable)
        if extractorManager.canExtract(url: url) {
            do {
                let result = try await extractorManager.extract(url: url)
                return convertToResolvedInfo(result, url: url)
            } catch {
                // Fall through to next strategy
                print("Native extractor failed: \(error.localizedDescription)")
            }
        }
        
        // Strategy 2: Try URL interception (more universal, but slower)
        if VideoURLInterceptor.canIntercept(url) {
            do {
                let interceptedURLs = try await interceptor.interceptVideoURLs(from: url, timeout: 20)
                
                if !interceptedURLs.isEmpty {
                    return ResolvedLinkInfo(
                        title: extractTitle(from: url),
                        uploader: nil,
                        webpageURL: url,
                        thumbnail: nil,
                        extractor: "URL Interception",
                        durationSeconds: nil,
                        entryCount: nil,
                        formats: nil
                    )
                }
            } catch {
                // Fall through to next strategy
                print("URL interception failed: \(error.localizedDescription)")
            }
        }
        
        // Strategy 3: Try external resolver (requires server)
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendResolverError.missingEndpoint
        }
        
        return try await externalResolver.info(
            sourceURL: url,
            template: template,
            argumentOverride: argumentOverride,
            endpoint: endpoint,
            token: token
        )
    }
    
    /// Resolve video and get download URL
    func resolve(
        url: String,
        template: DownloadTemplate,
        argumentOverride: String?,
        endpoint: String,
        token: String,
        delivery: ResolverDelivery
    ) async throws -> ResolveResponse {
        // Strategy 1: Try native extractor (fastest, most reliable)
        if extractorManager.canExtract(url: url) {
            do {
                let result = try await extractorManager.extract(url: url)
                return convertToResolveResponse(result, url: url, template: template)
            } catch {
                print("Native extractor failed: \(error.localizedDescription)")
            }
        }
        
        // Strategy 2: Try URL interception (more universal, but slower)
        if VideoURLInterceptor.canIntercept(url) {
            do {
                let interceptedURLs = try await interceptor.interceptVideoURLs(from: url, timeout: 20)
                
                if let firstVideoURL = interceptedURLs.first {
                    let filename = sanitizeFilename(extractTitle(from: url)) + ".mp4"
                    
                    return ResolveResponse(url: firstVideoURL, title: extractTitle(from: url), filename: filename, entries: nil)
                }
            } catch {
                print("URL interception failed: \(error.localizedDescription)")
            }
        }
        
        // Strategy 3: Try external resolver (requires server)
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendResolverError.missingEndpoint
        }
        
        return try await externalResolver.resolve(
            sourceURL: url,
            template: template,
            argumentOverride: argumentOverride,
            endpoint: endpoint,
            token: token,
            delivery: delivery
        )
    }
    
    /// Check if URL can be resolved
    func canResolve(_ url: String, hasExternalEndpoint: Bool) -> Bool {
        if extractorManager.canExtract(url: url) {
            return true
        }
        if VideoURLInterceptor.canIntercept(url) {
            return true
        }
        return hasExternalEndpoint && BackendResolver.needsResolver(url)
    }
    
    // MARK: - Private helpers
    
    private func convertToResolvedInfo(_ result: ExtractionResult, url: String) -> ResolvedLinkInfo {
        let formats = result.formats.map { format in
            ResolvedFormatInfo(
                id: format.id,
                fileExtension: extractExtension(from: format.mimeType),
                resolution: format.height.map { "\($0)p" },
                height: format.height,
                fps: format.fps,
                filesizeBytes: format.fileSize,
                bitrateKbps: format.bitrate.map { Double($0) / 1000.0 },
                note: format.quality,
                videoCodec: format.videoCodec,
                audioCodec: format.audioCodec,
                hasVideo: format.hasVideo,
                hasAudio: format.hasAudio
            )
        }
        
        return ResolvedLinkInfo(
            title: result.title,
            uploader: nil,
            webpageURL: url,
            thumbnail: result.thumbnailURL,
            extractor: extractorManager.extractor(for: url)?.platformName ?? "Unknown",
            durationSeconds: result.duration,
            entryCount: nil,
            formats: formats
        )
    }
    
    private func convertToResolveResponse(_ result: ExtractionResult, url: String, template: DownloadTemplate) -> ResolveResponse {
        if template.mode == .audio {
            let audioFormat = result.formats
                .filter { $0.hasAudio && !$0.hasVideo }
                .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
                ?? result.formats.first { $0.hasAudio }

            guard let audioFormat else {
                return ResolveResponse(url: nil, title: result.title, filename: sanitizeFilename(result.title) + ".m4a", entries: nil)
            }

            return ResolveResponse(
                url: audioFormat.url,
                title: result.title,
                filename: sanitizeFilename(result.title) + "." + (extractExtension(from: audioFormat.mimeType) ?? "m4a"),
                entries: nil
            )
        }

        guard let bestFormat = result.bestFormat else {
            return ResolveResponse(
                url: nil,
                title: result.title,
                filename: sanitizeFilename(result.title) + ".mp4",
                entries: nil
            )
        }

        if bestFormat.hasVideo && !bestFormat.hasAudio,
           let audioFormat = result.formats
            .filter({ $0.hasAudio && !$0.hasVideo })
            .max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return ResolveResponse(
                url: bestFormat.url,
                audioURL: audioFormat.url,
                title: result.title,
                filename: sanitizeFilename(result.title) + ".mp4",
                entries: nil
            )
        }

        let filename = sanitizeFilename(result.title) + "." + (extractExtension(from: bestFormat.mimeType) ?? "mp4")
        
        return ResolveResponse(
            url: bestFormat.url,
            title: result.title,
            filename: filename,
            entries: nil
        )
    }
    
    private func extractExtension(from mimeType: String) -> String? {
        if mimeType.contains("mp4") { return "mp4" }
        if mimeType.contains("webm") { return "webm" }
        if mimeType.contains("ogg") { return "ogg" }
        if mimeType.contains("mp3") { return "mp3" }
        if mimeType.contains("m4a") { return "m4a" }
        if mimeType.contains("x-flv") { return "flv" }
        return nil
    }
    
    private func extractTitle(from urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "Video" }
        
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if let lastComponent = pathComponents.last,
           !lastComponent.isEmpty,
           lastComponent != "watch",
           lastComponent != "video" {
            let cleaned = lastComponent
                .replacingOccurrences(of: ".html", with: "")
                .replacingOccurrences(of: ".htm", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            
            if !cleaned.isEmpty {
                return cleaned.capitalized
            }
        }
        
        return url.host ?? "Video"
    }
    
    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "video" : trimmed
    }
}
