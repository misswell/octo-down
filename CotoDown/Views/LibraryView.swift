import QuickLook
import SwiftUI

struct LibraryView: View {
    @StateObject private var library = FileLibraryStore()
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .modifiedNewest
    @State private var previewURL: URL?
    @State private var fileBeingRenamed: DownloadedFile?
    @State private var renameText = ""
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                if library.files.isEmpty {
                    ContentUnavailableView(
                        "No Files",
                        systemImage: "folder",
                        description: Text("Completed downloads will appear here.")
                    )
                } else if visibleFiles.isEmpty {
                    ContentUnavailableView(
                        "Nothing Found",
                        systemImage: "magnifyingglass",
                        description: Text("No files match your search.")
                    )
                } else {
                    Section {
                        ForEach(visibleFiles) { file in
                            FileRowView(file: file) {
                                previewURL = file.url
                            }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        library.delete(file)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        beginRename(file)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .contextMenu {
                                    Button {
                                        beginRename(file)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }

                                    Button {
                                        previewURL = file.url
                                    } label: {
                                        Label("Preview", systemImage: "eye")
                                    }

                                    ShareLink(item: file.url) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }

                                    Button(role: .destructive) {
                                        library.delete(file)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text(sectionHeader)
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search files")
            .quickLookPreview($previewURL)
            .alert("Rename File", isPresented: renameBinding) {
                TextField("File name", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Cancel", role: .cancel) {
                    fileBeingRenamed = nil
                    renameText = ""
                }

                Button("Rename") {
                    if let fileBeingRenamed {
                        library.rename(fileBeingRenamed, to: renameText)
                    }
                    fileBeingRenamed = nil
                    renameText = ""
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("The extension is kept when you omit one.")
            }
            .confirmationDialog(
                "Delete all files?",
                isPresented: $isConfirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Files", role: .destructive) {
                    library.deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every file shown in the coto down downloads folder.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(LibrarySortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort files")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            library.reload()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            isConfirmingDeleteAll = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                        .disabled(library.files.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Library actions")
                }
            }
            .onAppear {
                library.reload()
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var visibleFiles: [DownloadedFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? library.files
            : library.files.filter { file in
                file.name.localizedCaseInsensitiveContains(query)
                    || file.url.pathExtension.localizedCaseInsensitiveContains(query)
            }

        return filtered.sorted(by: sortOrder.areInIncreasingOrder)
    }

    private var sectionHeader: String {
        let countText = visibleFiles.count == library.files.count
            ? "\(library.files.count) files"
            : "\(visibleFiles.count) of \(library.files.count) files"
        return "\(countText) - \(byteString(visibleFiles.reduce(0) { $0 + $1.byteCount }))"
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { fileBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    fileBeingRenamed = nil
                    renameText = ""
                }
            }
        )
    }

    private func beginRename(_ file: DownloadedFile) {
        fileBeingRenamed = file
        renameText = file.name
    }
}

private struct FileRowView: View {
    let file: DownloadedFile
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(byteString(file.byteCount)) - \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onPreview) {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview file")

            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share file")
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch file.url.pathExtension.lowercased() {
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus":
            "waveform"
        case "mp4", "mov", "m4v", "mkv", "webm":
            "play.rectangle"
        case "srt", "vtt", "txt":
            "text.alignleft"
        default:
            "doc"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case modifiedNewest
    case modifiedOldest
    case nameAscending
    case nameDescending
    case sizeLargest
    case sizeSmallest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modifiedNewest: "Newest"
        case .modifiedOldest: "Oldest"
        case .nameAscending: "Name A-Z"
        case .nameDescending: "Name Z-A"
        case .sizeLargest: "Largest"
        case .sizeSmallest: "Smallest"
        }
    }

    var systemImage: String {
        switch self {
        case .modifiedNewest: "calendar.badge.clock"
        case .modifiedOldest: "calendar"
        case .nameAscending: "textformat.abc"
        case .nameDescending: "textformat.abc.dottedunderline"
        case .sizeLargest: "arrow.down.to.line.compact"
        case .sizeSmallest: "arrow.up.to.line.compact"
        }
    }

    func areInIncreasingOrder(_ lhs: DownloadedFile, _ rhs: DownloadedFile) -> Bool {
        switch self {
        case .modifiedNewest:
            lhs.modifiedAt > rhs.modifiedAt
        case .modifiedOldest:
            lhs.modifiedAt < rhs.modifiedAt
        case .nameAscending:
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .nameDescending:
            lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        case .sizeLargest:
            lhs.byteCount > rhs.byteCount
        case .sizeSmallest:
            lhs.byteCount < rhs.byteCount
        }
    }
}
