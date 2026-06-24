import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()

        Task {
            await handleSharedInput()
        }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Sending link(s) to coto down..."
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func handleSharedInput() async {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finishWithMessage("No link found.")
            return
        }

        let sharedURLStrings = await urlStrings(in: extensionItems)
        guard let callbackURL = callbackURL(for: sharedURLStrings) else {
            finishWithMessage("The shared link is not valid.")
            return
        }

        let success = await extensionContext?.open(callbackURL) ?? false
        if success {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            finishWithMessage("Could not open coto down.")
        }
    }

    private func urlStrings(in items: [NSExtensionItem]) async -> [String] {
        var urlStrings: [String] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if let url = await loadURL(from: provider) {
                    urlStrings.append(url.absoluteString)
                }

                if let text = await loadText(from: provider) {
                    urlStrings.append(contentsOf: Self.urlStrings(from: text))
                }
            }
        }

        return uniqueURLStrings(urlStrings)
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        let identifiers = [
            UTType.url.identifier
        ]

        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            if let item = await loadProviderItem(provider, typeIdentifier: identifier),
               let url = url(from: item) {
                return url
            }
        }

        return nil
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
            return nil
        }

        guard let item = await loadProviderItem(provider, typeIdentifier: UTType.plainText.identifier) else {
            return nil
        }

        if let text = item as? String {
            return text
        }

        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    private func loadProviderItem(_ provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private func url(from item: NSSecureCoding) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let string = item as? String {
            return URL(string: string)
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return URL(string: string)
        }

        return nil
    }

    private static func urlStrings(from text: String) -> [String] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        return matches.compactMap { $0.url?.absoluteString }
    }

    private func callbackURL(for urlStrings: [String]) -> URL? {
        let urlStrings = uniqueURLStrings(urlStrings)
        guard !urlStrings.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "coto-down"
        components.host = "download"
        components.queryItems = urlStrings.map { URLQueryItem(name: "url", value: $0) }
        return components.url
    }

    private func uniqueURLStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !seen.contains(value) else { return false }
            seen.insert(value)
            return true
        }
    }

    private func finishWithMessage(_ message: String) {
        statusLabel.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
