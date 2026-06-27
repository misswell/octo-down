import Foundation

struct CookieStore {
    private struct StoredCookie {
        var domain: String?
        var path: String
        var name: String
        var value: String
        var secure: Bool
    }

    static let storageKey = "platformCookies"

    static var rawCookieText: String {
        UserDefaults.standard.string(forKey: storageKey) ?? ""
    }

    static func cookieHeader(for url: URL) -> String? {
        let cookies = parse(rawCookieText)
            .filter { matches($0, url: url) }
        guard !cookies.isEmpty else { return nil }
        return cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func apply(to request: inout URLRequest, referer: String? = nil) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let url = request.url, let cookieHeader = cookieHeader(for: url) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    static func configuredSession(referer: String? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.default
        var headers = ["User-Agent": Self.userAgent]
        if let referer {
            headers["Referer"] = referer
        }
        configuration.httpAdditionalHeaders = headers
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }

    static func installIntoSharedStorage() {
        let storage = HTTPCookieStorage.shared
        for cookie in parse(rawCookieText) {
            guard let domain = cookie.domain else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: cookie.path,
                .name: cookie.name,
                .value: cookie.value,
                .secure: cookie.secure ? "TRUE" : "FALSE"
            ]
            if cookie.domain?.hasPrefix(".") == true {
                properties[.originURL] = "https://\(domain.dropFirst())"
            } else {
                properties[.originURL] = "https://\(domain)"
            }
            if let httpCookie = HTTPCookie(properties: properties) {
                storage.setCookie(httpCookie)
            }
        }
    }

    private static func parse(_ text: String) -> [StoredCookie] {
        text.components(separatedBy: .newlines)
            .flatMap(parseLine)
    }

    private static func parseLine(_ rawLine: String) -> [StoredCookie] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return [] }

        let netscapeColumns = line.components(separatedBy: "\t")
        if netscapeColumns.count >= 7 {
            let domain = netscapeColumns[0]
            let path = netscapeColumns[2].isEmpty ? "/" : netscapeColumns[2]
            let secure = netscapeColumns[3].uppercased() == "TRUE"
            let name = netscapeColumns[5]
            let value = netscapeColumns.dropFirst(6).joined(separator: "\t")
            return [StoredCookie(domain: domain, path: path, name: name, value: value, secure: secure)]
        }

        let header = line.lowercased().hasPrefix("cookie:")
            ? String(line.dropFirst("cookie:".count))
            : line

        return header
            .split(separator: ";")
            .compactMap { pair -> StoredCookie? in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return StoredCookie(domain: nil, path: "/", name: name, value: value, secure: false)
            }
    }

    private static func matches(_ cookie: StoredCookie, url: URL) -> Bool {
        guard cookie.secure == false || url.scheme == "https" else { return false }
        guard let domain = cookie.domain?.lowercased(), !domain.isEmpty else {
            return true
        }
        guard let host = url.host?.lowercased() else { return false }
        let normalizedDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)")
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
