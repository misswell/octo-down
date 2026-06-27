import Foundation

struct HLSDownloadProgress: Sendable {
    var completedSegments: Int
    var totalSegments: Int
    var receivedBytes: Int64
}

enum HLSDownloadError: LocalizedError {
    case invalidPlaylistURL
    case invalidPlaylist
    case unsupportedEncryption(String)
    case invalidEncryptionKey
    case decryptionFailed
    case liveStreamUnsupported
    case noSegments

    var errorDescription: String? {
        switch self {
        case .invalidPlaylistURL:
            "Invalid HLS playlist URL."
        case .invalidPlaylist:
            "The HLS playlist could not be parsed."
        case .unsupportedEncryption(let method):
            "HLS encryption method \(method) is not supported."
        case .invalidEncryptionKey:
            "The HLS encryption key could not be loaded."
        case .decryptionFailed:
            "The HLS segment could not be decrypted."
        case .liveStreamUnsupported:
            "Live HLS streams are not supported yet."
        case .noSegments:
            "The HLS playlist did not contain media segments."
        }
    }
}

struct HLSDownloader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        playlistURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (HLSDownloadProgress) -> Void
    ) async throws {
        let mediaPlaylist = try await resolveMediaPlaylist(from: playlistURL)
        guard mediaPlaylist.isLive == false else {
            throw HLSDownloadError.liveStreamUnsupported
        }
        guard !mediaPlaylist.segments.isEmpty else {
            throw HLSDownloadError.noSegments
        }

        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).part")
        try? fileManager.removeItem(at: temporaryURL)
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)

        var receivedBytes: Int64 = 0
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? handle.close()
            try? fileManager.removeItem(at: temporaryURL)
        }

        for (index, segment) in mediaPlaylist.segments.enumerated() {
            try Task.checkCancellation()
            var request = URLRequest(url: segment.url)
            CookieStore.apply(to: &request, referer: playlistURL.absoluteString)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            let outputData = try await decryptedDataIfNeeded(
                data,
                segment: segment,
                referer: playlistURL.absoluteString
            )
            try handle.write(contentsOf: outputData)
            receivedBytes += Int64(outputData.count)
            progress(
                HLSDownloadProgress(
                    completedSegments: index + 1,
                    totalSegments: mediaPlaylist.segments.count,
                    receivedBytes: receivedBytes
                )
            )
        }

        try handle.close()
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func decryptedDataIfNeeded(_ data: Data, segment: HLSSegment, referer: String) async throws -> Data {
        guard let key = segment.key else { return data }
        var request = URLRequest(url: key.uri)
        CookieStore.apply(to: &request, referer: referer)
        let (keyData, response) = try await session.data(for: request)
        try Self.validate(response)
        guard keyData.count == 16 else {
            throw HLSDownloadError.invalidEncryptionKey
        }
        return try Self.aes128CBCDecrypt(data: data, key: keyData, iv: key.iv)
    }

    private func resolveMediaPlaylist(from playlistURL: URL) async throws -> MediaPlaylist {
        let rootPlaylist = try await loadPlaylist(from: playlistURL)
        if let variantURL = rootPlaylist.bestVariantURL {
            return try await loadPlaylist(from: variantURL).mediaPlaylist(baseURL: variantURL)
        }
        return rootPlaylist.mediaPlaylist(baseURL: playlistURL)
    }

    private func loadPlaylist(from url: URL) async throws -> ParsedPlaylist {
        var request = URLRequest(url: url)
        CookieStore.apply(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSDownloadError.invalidPlaylist
        }
        return try ParsedPlaylist(text: text, baseURL: url)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendResolverError.httpStatus(http.statusCode)
        }
    }
}

@_silgen_name("CCCrypt")
private func commonCryptoCCCrypt(
    _ operation: UInt32,
    _ algorithm: UInt32,
    _ options: UInt32,
    _ key: UnsafeRawPointer,
    _ keyLength: Int,
    _ initializationVector: UnsafeRawPointer?,
    _ dataIn: UnsafeRawPointer,
    _ dataInLength: Int,
    _ dataOut: UnsafeMutableRawPointer,
    _ dataOutAvailable: Int,
    _ dataOutMoved: UnsafeMutablePointer<Int>
) -> Int32

private extension HLSDownloader {
    static func aes128CBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else {
            throw HLSDownloadError.invalidEncryptionKey
        }

        do {
            return try decrypt(data: data, key: key, iv: iv, options: 1)
        } catch {
            return try decrypt(data: data, key: key, iv: iv, options: 0)
        }
    }

    private static func decrypt(data: Data, key: Data, iv: Data, options: UInt32) throws -> Data {
        let outputCapacity = data.count + 16
        var output = Data(count: outputCapacity)
        var outputLength = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        commonCryptoCCCrypt(
                            1,
                            0,
                            options,
                            keyBytes.baseAddress!,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress!,
                            data.count,
                            outputBytes.baseAddress!,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == 0 else {
            throw HLSDownloadError.decryptionFailed
        }

        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

private struct MediaPlaylist {
    var segments: [HLSSegment]
    var isLive: Bool
}

private struct HLSSegment {
    var url: URL
    var key: HLSKey?
}

private struct HLSKey {
    var uri: URL
    var iv: Data
}

private struct ParsedKey {
    var method: String
    var uri: URL?
    var explicitIV: Data?
}

private struct ParsedPlaylist {
    private struct Variant {
        var url: URL
        var bandwidth: Int
    }

    private var variants: [Variant] = []
    private var segments: [HLSSegment] = []
    private var ended = false

    var bestVariantURL: URL? {
        variants.max { $0.bandwidth < $1.bandwidth }?.url
    }

    init(text: String, baseURL: URL) throws {
        let rawLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard rawLines.first == "#EXTM3U" else {
            throw HLSDownloadError.invalidPlaylist
        }

        var pendingVariantBandwidth: Int?
        var currentKey: ParsedKey?
        var mediaSequence = 0
        var segmentSequence = 0

        for line in rawLines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingVariantBandwidth = Self.attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
                continue
            }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                mediaSequence = line
                    .split(separator: ":", maxSplits: 1)
                    .last
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                segmentSequence = 0
                continue
            }

            if line.hasPrefix("#EXT-X-KEY") {
                let method = Self.attribute("METHOD", in: line)?.uppercased()
                if method == nil || method == "NONE" {
                    currentKey = nil
                    continue
                }
                guard method == "AES-128" else {
                    throw HLSDownloadError.unsupportedEncryption(method ?? "unknown")
                }
                let keyURL = Self.attribute("URI", in: line)
                    .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                currentKey = ParsedKey(
                    method: method ?? "AES-128",
                    uri: keyURL,
                    explicitIV: Self.ivData(from: Self.attribute("IV", in: line))
                )
                continue
            }

            if line == "#EXT-X-ENDLIST" {
                ended = true
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            if let bandwidth = pendingVariantBandwidth {
                variants.append(Variant(url: url, bandwidth: bandwidth))
                pendingVariantBandwidth = nil
            } else {
                segments.append(
                    HLSSegment(
                        url: url,
                        key: try currentKey.map {
                            try Self.key(from: $0, sequence: mediaSequence + segmentSequence)
                        }
                    )
                )
                segmentSequence += 1
            }
        }
    }

    func mediaPlaylist(baseURL: URL) -> MediaPlaylist {
        MediaPlaylist(
            segments: segments,
            isLive: !ended
        )
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        let prefix = "\(name)="
        guard let range = line.range(of: prefix) else { return nil }
        let tail = line[range.upperBound...]
        if tail.first == "\"" {
            let quoted = tail.dropFirst()
            return quoted.split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
        return tail
            .split(separator: ",", maxSplits: 1)
            .first
            .map(String.init)
    }

    private static func key(from parsedKey: ParsedKey, sequence: Int) throws -> HLSKey {
        guard let uri = parsedKey.uri else {
            throw HLSDownloadError.invalidEncryptionKey
        }
        return HLSKey(
            uri: uri,
            iv: parsedKey.explicitIV ?? sequenceIV(sequence)
        )
    }

    private static func ivData(from value: String?) -> Data? {
        guard var hex = value?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.count % 2 == 1 {
            hex = "0\(hex)"
        }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        guard data.count <= 16 else { return nil }
        if data.count < 16 {
            data.insert(contentsOf: repeatElement(0, count: 16 - data.count), at: 0)
        }
        return data
    }

    private static func sequenceIV(_ sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(max(sequence, 0))
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xff)
            value >>= 8
        }
        return Data(bytes)
    }
}
