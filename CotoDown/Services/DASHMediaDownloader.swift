import AVFoundation
import Foundation

enum DASHMediaDownloadError: LocalizedError {
    case invalidMediaURL
    case invalidDownloadedMedia
    case exportSessionUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidMediaURL:
            "Invalid separated media URL."
        case .invalidDownloadedMedia:
            "Downloaded media tracks could not be read."
        case .exportSessionUnavailable:
            "This video and audio combination cannot be merged on device."
        case .exportFailed:
            "The separated video and audio streams could not be merged."
        }
    }
}

struct DASHMediaDownloadProgress: Sendable {
    enum Stage: String, Sendable {
        case downloadingVideo
        case downloadingAudio
        case merging
    }

    var stage: Stage
    var progress: Double
}

struct DASHMediaDownloader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func downloadAndMerge(
        videoURL: URL,
        audioURL: URL,
        pageURL: URL?,
        destinationURL: URL,
        progress: @escaping @Sendable (DASHMediaDownloadProgress) -> Void
    ) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coto-down-dash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        progress(DASHMediaDownloadProgress(stage: .downloadingVideo, progress: 0.05))
        let videoFile = try await download(
            mediaURL: videoURL,
            pageURL: pageURL,
            to: temporaryDirectory.appendingPathComponent("video.\(Self.fileExtension(for: videoURL, fallback: "mp4"))")
        )

        progress(DASHMediaDownloadProgress(stage: .downloadingAudio, progress: 0.45))
        let audioFile = try await download(
            mediaURL: audioURL,
            pageURL: pageURL,
            to: temporaryDirectory.appendingPathComponent("audio.\(Self.fileExtension(for: audioURL, fallback: "m4a"))")
        )

        progress(DASHMediaDownloadProgress(stage: .merging, progress: 0.8))
        try await merge(videoURL: videoFile, audioURL: audioFile, destinationURL: destinationURL)
        progress(DASHMediaDownloadProgress(stage: .merging, progress: 1))
    }

    private func download(mediaURL: URL, pageURL: URL?, to destinationURL: URL) async throws -> URL {
        var request = URLRequest(url: mediaURL)
        CookieStore.apply(to: &request, referer: Self.referer(for: mediaURL, pageURL: pageURL))

        let (temporaryURL, response) = try await session.download(for: request)
        try Self.validate(response)
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func merge(videoURL: URL, audioURL: URL, destinationURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else {
            throw DASHMediaDownloadError.invalidDownloadedMedia
        }

        let duration = try await videoAsset.load(.duration)
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
              let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw DASHMediaDownloadError.exportSessionUnavailable
        }

        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideoTrack, at: .zero)
        let audioDuration = try await audioAsset.load(.duration)
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: min(duration, audioDuration)),
            of: sourceAudioTrack,
            at: .zero
        )

        try? FileManager.default.removeItem(at: destinationURL)
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DASHMediaDownloadError.exportSessionUnavailable
        }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        try await export(exportSession)
    }

    private func export(_ exportSession: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exportSession.error ?? DASHMediaDownloadError.exportFailed)
                default:
                    continuation.resume(throwing: DASHMediaDownloadError.exportFailed)
                }
            }
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendResolverError.httpStatus(http.statusCode)
        }
    }

    private static func fileExtension(for url: URL, fallback: String) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? fallback : ext
    }

    private static func referer(for mediaURL: URL, pageURL: URL?) -> String? {
        if mediaURL.host?.contains("bilivideo") == true || pageURL?.host?.contains("bilibili") == true {
            return "https://www.bilibili.com/"
        }
        guard let pageURL else { return nil }
        return pageURL.absoluteString
    }

}
