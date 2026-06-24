import Foundation

struct DownloadedFile: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var name: String
    var byteCount: Int64
    var modifiedAt: Date
}

@MainActor
final class FileLibraryStore: ObservableObject {
    @Published private(set) var files: [DownloadedFile] = []
    @Published private(set) var totalByteCount: Int64 = 0

    func reload() {
        let folder = Self.downloadsFolderURL()
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            totalByteCount = 0
            return
        }

        let loadedFiles = urls.compactMap { url -> DownloadedFile? in
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true
            else {
                return nil
            }

            return DownloadedFile(
                url: url,
                name: url.lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }

        files = loadedFiles
        totalByteCount = loadedFiles.reduce(0) { $0 + $1.byteCount }
    }

    func delete(_ file: DownloadedFile) {
        try? FileManager.default.removeItem(at: file.url)
        reload()
    }

    func deleteAll() {
        for file in files {
            try? FileManager.default.removeItem(at: file.url)
        }
        reload()
    }

    func rename(_ file: DownloadedFile, to proposedName: String) {
        let sanitizedName = Self.sanitizedFileName(proposedName)
        guard !sanitizedName.isEmpty else { return }

        let finalName: String
        if URL(fileURLWithPath: sanitizedName).pathExtension.isEmpty,
           !file.url.pathExtension.isEmpty {
            finalName = "\(sanitizedName).\(file.url.pathExtension)"
        } else {
            finalName = sanitizedName
        }

        let destination = Self.availableFileURL(
            for: file.url.deletingLastPathComponent().appendingPathComponent(finalName),
            excluding: file.url
        )

        guard destination.path != file.url.path else { return }
        try? FileManager.default.moveItem(at: file.url, to: destination)
        reload()
    }

    nonisolated static func downloadsFolderURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Coto Down Downloads", isDirectory: true)
    }

    private nonisolated static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func availableFileURL(for candidate: URL, excluding original: URL) -> URL {
        if candidate.path == original.path || !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let directory = candidate.deletingLastPathComponent()
        let fileExtension = candidate.pathExtension
        let baseName = candidate.deletingPathExtension().lastPathComponent

        for index in 2...10_000 {
            let fileName = fileExtension.isEmpty
                ? "\(baseName) \(index)"
                : "\(baseName) \(index).\(fileExtension)"
            let nextURL = directory.appendingPathComponent(fileName)
            if nextURL.path == original.path || !FileManager.default.fileExists(atPath: nextURL.path) {
                return nextURL
            }
        }

        let fallbackName = fileExtension.isEmpty
            ? "\(baseName) \(UUID().uuidString)"
            : "\(baseName) \(UUID().uuidString).\(fileExtension)"
        return directory.appendingPathComponent(fallbackName)
    }
}
