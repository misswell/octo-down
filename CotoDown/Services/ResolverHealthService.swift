import Foundation

struct ResolverHealthResponse: Decodable {
    var ok: Bool
}

enum ResolverHealthError: LocalizedError {
    case missingEndpoint
    case invalidEndpoint
    case unhealthy

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            "Enter a resolver endpoint first."
        case .invalidEndpoint:
            "The resolver endpoint is not a valid URL."
        case .unhealthy:
            "The resolver did not report healthy status."
        }
    }
}

struct ResolverHealthService {
    func check(endpoint: String, token: String) async throws {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            throw ResolverHealthError.missingEndpoint
        }
        guard let healthURL = Self.healthURL(from: trimmedEndpoint) else {
            throw ResolverHealthError.invalidEndpoint
        }

        var request = URLRequest(url: healthURL)
        BackendResolver.applyAuthorization(token: token, to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ResolverHealthResponse.self, from: data)
        guard decoded.ok else {
            throw ResolverHealthError.unhealthy
        }
    }

    nonisolated static func healthURL(from endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else {
            return nil
        }

        var pathComponents = components.path.split(separator: "/").map(String.init)
        if pathComponents.last == "resolve" {
            pathComponents.removeLast()
        }
        pathComponents.append("health")
        components.path = "/" + pathComponents.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
