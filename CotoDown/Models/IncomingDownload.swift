import Foundation

struct IncomingDownload: Identifiable, Equatable {
    var id = UUID()
    var urlStrings: [String]
    var templateName: String?
    var argumentOverride: String?
    var preferredFileName: String?
    var startsImmediately: Bool

    var urlString: String {
        urlStrings.first ?? ""
    }

    init(
        urlString: String,
        templateName: String? = nil,
        argumentOverride: String? = nil,
        preferredFileName: String? = nil,
        startsImmediately: Bool
    ) {
        self.urlStrings = [urlString]
        self.templateName = templateName
        self.argumentOverride = argumentOverride
        self.preferredFileName = preferredFileName
        self.startsImmediately = startsImmediately
    }

    init(
        urlStrings: [String],
        templateName: String? = nil,
        argumentOverride: String? = nil,
        preferredFileName: String? = nil,
        startsImmediately: Bool
    ) {
        self.urlStrings = urlStrings
        self.templateName = templateName
        self.argumentOverride = argumentOverride
        self.preferredFileName = preferredFileName
        self.startsImmediately = startsImmediately
    }
}

@MainActor
final class IncomingLinkInbox: ObservableObject {
    @Published var pending: IncomingDownload?

    func receive(_ url: URL) {
        if let incoming = Self.incomingDownload(from: url) {
            pending = incoming
        }
    }

    func clear(_ incoming: IncomingDownload) {
        if pending?.id == incoming.id {
            pending = nil
        }
    }

    private nonisolated static func incomingDownload(from url: URL) -> IncomingDownload? {
        if url.scheme == "http" || url.scheme == "https" {
            return IncomingDownload(urlString: url.absoluteString, startsImmediately: false)
        }

        guard url.scheme == "coto-down" || url.scheme == "cotodown",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let urlStrings = uniqueURLStrings(
            queryItems
                .filter { $0.name == "url" }
                .compactMap(\.value)
                + queryItems
                    .filter { $0.name == "urls" }
                    .compactMap(\.value)
                    .flatMap { $0.components(separatedBy: .newlines) }
        )
        guard !urlStrings.isEmpty else {
            return nil
        }

        let templateName = queryItems.first(where: { $0.name == "template" })?.value
        let argumentOverride = queryItems.first(where: { $0.name == "arguments" || $0.name == "args" })?.value
        let preferredFileName = queryItems.first(where: { $0.name == "filename" || $0.name == "name" })?.value
        let startValue = queryItems.first(where: { $0.name == "start" })?.value?.lowercased()
        let startsImmediately = startValue == "1" || startValue == "true" || startValue == "yes"

        return IncomingDownload(
            urlStrings: urlStrings,
            templateName: templateName,
            argumentOverride: argumentOverride,
            preferredFileName: preferredFileName,
            startsImmediately: startsImmediately
        )
    }

    private nonisolated static func uniqueURLStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(string: trimmed) != nil, !seen.contains(trimmed) else {
                return nil
            }
            seen.insert(trimmed)
            return trimmed
        }
    }
}
