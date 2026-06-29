import AVFoundation
import Foundation

/// Retry a throwing operation with exponential backoff (max 3 attempts, ~6s total)
private func retryWithBackoff<T>(
    maxAttempts: Int = 3,
    operation: @escaping () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < maxAttempts {
                let delay = Double(1 << (attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    throw lastError ?? BackendResolverError.httpStatus(0)
}

enum DASHMediaDownloadError: LocalizedError {
    case invalidMediaURL
    case invalidManifest
    case unsupportedManifest(String)
    case noPlayableRepresentations
    case invalidDownloadedMedia
    case exportSessionUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidMediaURL:
            "Invalid separated media URL."
        case .invalidManifest:
            "The DASH manifest could not be parsed."
        case .unsupportedManifest(let reason):
            "This DASH manifest is not supported yet: \(reason)."
        case .noPlayableRepresentations:
            "The DASH manifest did not contain playable video and audio representations."
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

    func downloadManifestAndMerge(
        manifestURL: URL,
        pageURL: URL?,
        destinationURL: URL,
        progress: @escaping @Sendable (DASHMediaDownloadProgress) -> Void
    ) async throws {
        var request = URLRequest(url: manifestURL)
        CookieStore.apply(to: &request, referer: pageURL?.absoluteString)
        let (data, response) = try await retryWithBackoff {
            let (d, r) = try await session.data(for: request)
            try Self.validate(r)
            return (d, r)
        }
        guard let xml = String(data: data, encoding: .utf8) else {
            throw DASHMediaDownloadError.invalidManifest
        }

        let manifest = try DASHManifestParser(manifestURL: manifestURL).parse(xml)
        let streams = try manifest.bestPlayableStreams()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coto-down-mpd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        progress(DASHMediaDownloadProgress(stage: .downloadingVideo, progress: 0.05))
        let videoFile = try await download(
            stream: streams.video,
            pageURL: pageURL ?? manifestURL,
            to: temporaryDirectory.appendingPathComponent("video.\(streams.video.fileExtension)")
        ) { streamProgress in
            progress(DASHMediaDownloadProgress(stage: .downloadingVideo, progress: 0.05 + streamProgress * 0.35))
        }

        progress(DASHMediaDownloadProgress(stage: .downloadingAudio, progress: 0.45))
        let audioFile = try await download(
            stream: streams.audio,
            pageURL: pageURL ?? manifestURL,
            to: temporaryDirectory.appendingPathComponent("audio.\(streams.audio.fileExtension)")
        ) { streamProgress in
            progress(DASHMediaDownloadProgress(stage: .downloadingAudio, progress: 0.45 + streamProgress * 0.3))
        }

        progress(DASHMediaDownloadProgress(stage: .merging, progress: 0.8))
        try await merge(videoURL: videoFile, audioURL: audioFile, destinationURL: destinationURL)
        progress(DASHMediaDownloadProgress(stage: .merging, progress: 1))
    }

    private func download(mediaURL: URL, pageURL: URL?, to destinationURL: URL) async throws -> URL {
        var request = URLRequest(url: mediaURL)
        CookieStore.apply(to: &request, referer: Self.referer(for: mediaURL, pageURL: pageURL))

        let (temporaryURL, response) = try await retryWithBackoff {
            let (t, r) = try await session.download(for: request)
            try Self.validate(r)
            return (t, r)
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func download(
        stream: DASHManifest.Stream,
        pageURL: URL?,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: destinationURL)

        if stream.urls.count == 1 {
            return try await download(mediaURL: stream.urls[0], pageURL: pageURL, to: destinationURL)
        }

        let urls = stream.urls
        let total = urls.count
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var results: [Int: Data] = [:]
            let maxConcurrent = 4

            for index in urls.indices {
                if index >= maxConcurrent {
                    if let (completedIndex, data) = try await group.next() {
                        results[completedIndex] = data
                    }
                }
                let url = urls[index]
                group.addTask { [session, pageURL] in
                    try Task.checkCancellation()
                    var request = URLRequest(url: url)
                    CookieStore.apply(to: &request, referer: pageURL?.absoluteString)
                    let (data, response) = try await retryWithBackoff {
                        let (d, r) = try await session.data(for: request)
                        try DASHMediaDownloader.validate(r)
                        return (d, r)
                    }
                    return (index, data)
                }
            }

            for _ in urls.indices {
                if let (completedIndex, data) = try await group.next() {
                    results[completedIndex] = data
                }
            }

            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? handle.close()
            }

            for index in urls.indices.sorted() {
                guard let data = results[index] else { continue }
                try handle.write(contentsOf: data)
                progress(Double(index + 1) / Double(total))
            }
        }

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

private struct DASHManifest {
    struct Stream {
        enum Kind {
            case video
            case audio
        }

        var kind: Kind
        var id: String
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var mimeType: String?
        var codecs: String?
        var urls: [URL]

        var fileExtension: String {
            if mimeType?.contains("webm") == true { return "webm" }
            if kind == .audio { return "m4a" }
            return "mp4"
        }
    }

    var streams: [Stream]

    func bestPlayableStreams() throws -> (video: Stream, audio: Stream) {
        guard let video = streams
            .filter({ $0.kind == .video })
            .max(by: { lhs, rhs in
                let lhsHeight = lhs.height ?? 0
                let rhsHeight = rhs.height ?? 0
                if lhsHeight == rhsHeight {
                    return lhs.bandwidth < rhs.bandwidth
                }
                return lhsHeight < rhsHeight
            }),
              let audio = streams
            .filter({ $0.kind == .audio })
            .max(by: { $0.bandwidth < $1.bandwidth })
        else {
            throw DASHMediaDownloadError.noPlayableRepresentations
        }

        return (video, audio)
    }
}

private struct DASHSegmentTemplate {
    var initialization: String?
    var media: String?
    var startNumber: Int
    var duration: Double?
    var timescale: Double
    var timeline: [DASHSegmentTimelineEntry] = []
}

private struct DASHSegmentTimelineEntry {
    var startTime: Int?
    var duration: Int
    var repeatCount: Int
}

private final class DASHManifestParser: NSObject, XMLParserDelegate {
    private struct AdaptationContext {
        var contentType: String?
        var mimeType: String?
        var codecs: String?
        var baseURL: URL
        var segmentTemplate: DASHSegmentTemplate?
    }

    private struct RepresentationContext {
        var id: String
        var bandwidth: Int
        var width: Int?
        var height: Int?
        var mimeType: String?
        var codecs: String?
        var baseURL: URL
        var segmentTemplate: DASHSegmentTemplate?
    }

    private let manifestURL: URL
    private var rootBaseURL: URL
    private var manifestDurationSeconds: Double?
    private var manifestType: String?
    private var periodBaseURL: URL?
    private var adaptation: AdaptationContext?
    private var representation: RepresentationContext?
    private var baseURLTarget: String?
    private var baseURLText = ""
    private var insideSegmentTimeline = false
    private var streams: [DASHManifest.Stream] = []
    private var parseError: Error?

    init(manifestURL: URL) {
        self.manifestURL = manifestURL
        rootBaseURL = manifestURL
    }

    func parse(_ xml: String) throws -> DASHManifest {
        guard let data = xml.data(using: .utf8) else {
            throw DASHMediaDownloadError.invalidManifest
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), parseError == nil else {
            throw parseError ?? parser.parserError ?? DASHMediaDownloadError.invalidManifest
        }
        if manifestType?.lowercased() == "dynamic" {
            throw DASHMediaDownloadError.unsupportedManifest("live MPD")
        }
        return DASHManifest(streams: streams)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "MPD":
            manifestType = attributeDict["type"]
            manifestDurationSeconds = Self.durationSeconds(attributeDict["mediaPresentationDuration"])
        case "Period":
            periodBaseURL = rootBaseURL
        case "AdaptationSet":
            adaptation = AdaptationContext(
                contentType: attributeDict["contentType"],
                mimeType: attributeDict["mimeType"],
                codecs: attributeDict["codecs"],
                baseURL: periodBaseURL ?? rootBaseURL,
                segmentTemplate: nil
            )
        case "Representation":
            guard let adaptation else { return }
            representation = RepresentationContext(
                id: attributeDict["id"] ?? UUID().uuidString,
                bandwidth: attributeDict["bandwidth"].flatMap(Int.init) ?? 0,
                width: attributeDict["width"].flatMap(Int.init),
                height: attributeDict["height"].flatMap(Int.init),
                mimeType: attributeDict["mimeType"] ?? adaptation.mimeType,
                codecs: attributeDict["codecs"] ?? adaptation.codecs,
                baseURL: adaptation.baseURL,
                segmentTemplate: adaptation.segmentTemplate
            )
        case "SegmentTemplate":
            let template = DASHSegmentTemplate(
                initialization: attributeDict["initialization"],
                media: attributeDict["media"],
                startNumber: attributeDict["startNumber"].flatMap(Int.init) ?? 1,
                duration: attributeDict["duration"].flatMap(Double.init),
                timescale: attributeDict["timescale"].flatMap(Double.init) ?? 1,
                timeline: []
            )
            if representation != nil {
                representation?.segmentTemplate = template
            } else {
                adaptation?.segmentTemplate = template
            }
        case "SegmentTimeline":
            insideSegmentTimeline = true
        case "S":
            guard insideSegmentTimeline,
                  let duration = attributeDict["d"].flatMap(Int.init)
            else {
                return
            }
            appendTimelineEntry(
                DASHSegmentTimelineEntry(
                    startTime: attributeDict["t"].flatMap(Int.init),
                    duration: duration,
                    repeatCount: attributeDict["r"].flatMap(Int.init) ?? 0
                )
            )
        case "BaseURL":
            baseURLText = ""
            if representation != nil {
                baseURLTarget = "representation"
            } else if adaptation != nil {
                baseURLTarget = "adaptation"
            } else if periodBaseURL != nil {
                baseURLTarget = "period"
            } else {
                baseURLTarget = "root"
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if baseURLTarget != nil {
            baseURLText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "BaseURL":
            applyBaseURL()
        case "SegmentTimeline":
            insideSegmentTimeline = false
        case "Representation":
            if let representation, let stream = stream(from: representation) {
                streams.append(stream)
            }
            representation = nil
        case "AdaptationSet":
            adaptation = nil
        case "Period":
            periodBaseURL = nil
        default:
            break
        }
    }

    private func appendTimelineEntry(_ entry: DASHSegmentTimelineEntry) {
        if representation != nil {
            representation?.segmentTemplate?.timeline.append(entry)
        } else {
            adaptation?.segmentTemplate?.timeline.append(entry)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    private func applyBaseURL() {
        let value = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            baseURLTarget = nil
            baseURLText = ""
        }
        guard !value.isEmpty else { return }

        switch baseURLTarget {
        case "representation":
            if let base = URL(string: value, relativeTo: representation?.baseURL ?? rootBaseURL)?.absoluteURL {
                representation?.baseURL = base
            }
        case "adaptation":
            if let base = URL(string: value, relativeTo: adaptation?.baseURL ?? rootBaseURL)?.absoluteURL {
                adaptation?.baseURL = base
            }
        case "period":
            if let base = URL(string: value, relativeTo: periodBaseURL ?? rootBaseURL)?.absoluteURL {
                periodBaseURL = base
            }
        case "root":
            if let base = URL(string: value, relativeTo: rootBaseURL)?.absoluteURL {
                rootBaseURL = base
            }
        default:
            break
        }
    }

    private func stream(from representation: RepresentationContext) -> DASHManifest.Stream? {
        guard let kind = streamKind(for: representation) else { return nil }
        let streamURLs: [URL]
        if let template = representation.segmentTemplate {
            guard let generated = urls(from: template, representation: representation), !generated.isEmpty else {
                return nil
            }
            streamURLs = generated
        } else {
            streamURLs = [representation.baseURL]
        }

        return DASHManifest.Stream(
            kind: kind,
            id: representation.id,
            bandwidth: representation.bandwidth,
            width: representation.width,
            height: representation.height,
            mimeType: representation.mimeType,
            codecs: representation.codecs,
            urls: streamURLs
        )
    }

    private func streamKind(for representation: RepresentationContext) -> DASHManifest.Stream.Kind? {
        let joined = [
            adaptation?.contentType,
            representation.mimeType,
            representation.codecs
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if joined.contains("audio") || joined.contains("mp4a") || joined.contains("opus") {
            return .audio
        }
        if joined.contains("video") || representation.width != nil || representation.height != nil {
            return .video
        }
        return nil
    }

    private func urls(from template: DASHSegmentTemplate, representation: RepresentationContext) -> [URL]? {
        guard let media = template.media, template.timescale > 0 else {
            return nil
        }

        var urls: [URL] = []
        if let initialization = template.initialization,
           let initializationURL = templateURL(initialization, representation: representation, number: nil, time: nil) {
            urls.append(initializationURL)
        }

        if !template.timeline.isEmpty {
            guard let timelineURLs = timelineURLs(from: template, representation: representation, media: media) else {
                return nil
            }
            urls.append(contentsOf: timelineURLs)
            return urls
        }

        guard let duration = template.duration,
              duration > 0,
              let manifestDurationSeconds,
              manifestDurationSeconds > 0
        else {
            return nil
        }

        let segmentSeconds = duration / template.timescale
        let segmentCount = min(max(Int(ceil(manifestDurationSeconds / segmentSeconds)), 1), 10_000)
        for offset in 0..<segmentCount {
            let number = template.startNumber + offset
            guard let url = templateURL(media, representation: representation, number: number, time: nil) else {
                return nil
            }
            urls.append(url)
        }
        return urls
    }

    private func timelineURLs(
        from template: DASHSegmentTemplate,
        representation: RepresentationContext,
        media: String
    ) -> [URL]? {
        var urls: [URL] = []
        var currentTime = 0
        var number = template.startNumber
        let maxSegments = 10_000

        for (index, entry) in template.timeline.enumerated() {
            if let startTime = entry.startTime {
                currentTime = startTime
            }

            let repeatCount: Int
            if entry.repeatCount >= 0 {
                repeatCount = entry.repeatCount
            } else if let nextStartTime = template.timeline.dropFirst(index + 1).first(where: { $0.startTime != nil })?.startTime {
                repeatCount = max((nextStartTime - currentTime) / entry.duration - 1, 0)
            } else if let manifestDurationSeconds {
                let manifestTicks = Int(ceil(manifestDurationSeconds * template.timescale))
                repeatCount = max((manifestTicks - currentTime) / entry.duration - 1, 0)
            } else {
                return nil
            }

            for _ in 0...repeatCount {
                guard urls.count < maxSegments,
                      let url = templateURL(media, representation: representation, number: number, time: currentTime)
                else {
                    return nil
                }
                urls.append(url)
                currentTime += entry.duration
                number += 1
            }
        }

        return urls
    }

    private func templateURL(_ value: String, representation: RepresentationContext, number: Int?, time: Int?) -> URL? {
        var path = value.replacingOccurrences(of: "$RepresentationID$", with: representation.id)
        if let number {
            path = Self.replaceNumberToken(in: path, number: number)
        }
        if let time {
            path = Self.replaceToken(in: path, name: "Time", value: time)
        }
        return URL(string: path, relativeTo: representation.baseURL)?.absoluteURL
    }

    private static func replaceNumberToken(in value: String, number: Int) -> String {
        replaceToken(in: value, name: "Number", value: number)
    }

    private static func replaceToken(in value: String, name: String, value numericValue: Int) -> String {
        var result = value.replacingOccurrences(of: "$\(name)$", with: "\(numericValue)")
        while let range = result.range(of: #"\$TOKEN%0\d+d\$"#.replacingOccurrences(of: "TOKEN", with: name), options: .regularExpression) {
            let token = String(result[range])
            let widthText = token
                .replacingOccurrences(of: "$\(name)%0", with: "")
                .replacingOccurrences(of: "d$", with: "")
            let width = Int(widthText) ?? 1
            let formatted = String(format: "%0\(width)d", numericValue)
            result.replaceSubrange(range, with: formatted)
        }
        return result
    }

    private static func durationSeconds(_ value: String?) -> Double? {
        guard let value, value.hasPrefix("P") else { return nil }
        let pattern = #"P(?:([\d.]+)D)?(?:T(?:([\d.]+)H)?(?:([\d.]+)M)?(?:([\d.]+)S)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else {
            return nil
        }

        func number(at index: Int) -> Double {
            guard let range = Range(match.range(at: index), in: value) else { return 0 }
            return Double(value[range]) ?? 0
        }

        return number(at: 1) * 86_400 + number(at: 2) * 3_600 + number(at: 3) * 60 + number(at: 4)
    }
}
