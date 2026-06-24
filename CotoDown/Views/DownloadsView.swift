import QuickLook
import SwiftUI
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var filter: DownloadFilter = .all
    @State private var searchText = ""
    @State private var selectedTask: DownloadTaskItem?

    var body: some View {
        NavigationStack {
            List {
                if downloadManager.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Paste a link to start a new download.")
                    )
                } else if visibleTasks.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: emptyStateImage,
                        description: Text(emptyStateMessage)
                    )
                } else {
                    ForEach(visibleTasks) { item in
                        TaskRowView(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedTask = item
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloadManager.delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if item.status == .paused {
                                    Button {
                                        downloadManager.resume(item, settings: settings)
                                    } label: {
                                        Label("Resume", systemImage: "play")
                                    }
                                    .tint(.blue)
                                }

                                if item.status == .failed || item.status == .cancelled {
                                    Button {
                                        downloadManager.retry(item, settings: settings)
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                    }
                                    .tint(.blue)
                                }

                                if item.status == .downloading {
                                    Button {
                                        downloadManager.pause(item)
                                    } label: {
                                        Label("Pause", systemImage: "pause")
                                    }
                                    .tint(.orange)
                                }

                                if item.status == .resolving || item.status == .queued {
                                    if item.status == .queued {
                                        Button {
                                            downloadManager.promoteQueued(item)
                                        } label: {
                                            Label("Make Next", systemImage: "arrow.up.to.line")
                                        }
                                        .tint(.purple)
                                    }

                                    Button {
                                        downloadManager.cancel(item)
                                    } label: {
                                        Label("Cancel", systemImage: "xmark")
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                }
            }
            .navigationTitle("Downloads")
            .searchable(text: $searchText, prompt: "Search downloads")
            .sheet(item: $selectedTask) { item in
                TaskDetailView(
                    item: item,
                    retry: {
                        downloadManager.retry(item, settings: settings)
                    },
                    resume: {
                        downloadManager.resume(item, settings: settings)
                    },
                    pause: {
                        downloadManager.pause(item)
                    },
                    cancel: {
                        downloadManager.cancel(item)
                    },
                    promote: {
                        downloadManager.promoteQueued(item)
                    },
                    delete: {
                        selectedTask = nil
                        downloadManager.delete(item)
                    }
                )
            }
            .safeAreaInset(edge: .top) {
                Picker("Filter", selection: $filter) {
                    ForEach(DownloadFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.systemImage).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            downloadManager.pauseAll()
                        } label: {
                            Label("Pause All", systemImage: "pause")
                        }
                        .disabled(!hasDownloadingTasks)

                        Button {
                            downloadManager.resumeAll(settings: settings)
                        } label: {
                            Label("Resume All", systemImage: "play")
                        }
                        .disabled(!hasPausedTasks)

                        Button {
                            downloadManager.retryFailed(settings: settings)
                        } label: {
                            Label("Retry Failed", systemImage: "arrow.clockwise")
                        }
                        .disabled(!hasFailedTasks)

                        Button(role: .destructive) {
                            downloadManager.cancelActive()
                        } label: {
                            Label("Cancel Active", systemImage: "xmark.circle")
                        }
                        .disabled(!hasCancellableTasks)

                        Button {
                            downloadManager.clearFinished()
                        } label: {
                            Label("Clear Finished", systemImage: "checkmark.circle")
                        }
                        .disabled(!hasClearableTasks)

                        Button(role: .destructive) {
                            downloadManager.clearFailed()
                        } label: {
                            Label("Clear Failed", systemImage: "exclamationmark.triangle")
                        }
                        .disabled(!hasFailedTasks)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Queue actions")
                }
            }
        }
    }

    private var filteredTasks: [DownloadTaskItem] {
        downloadManager.tasks.filter { filter.includes($0.status) }
    }

    private var visibleTasks: [DownloadTaskItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filteredTasks }

        return filteredTasks.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.sourceURL.localizedCaseInsensitiveContains(query)
                || item.resolvedURL?.localizedCaseInsensitiveContains(query) == true
                || item.fileName?.localizedCaseInsensitiveContains(query) == true
                || item.message?.localizedCaseInsensitiveContains(query) == true
                || item.templateName.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasDownloadingTasks: Bool {
        downloadManager.tasks.contains { $0.status == .downloading }
    }

    private var hasPausedTasks: Bool {
        downloadManager.tasks.contains { $0.status == .paused }
    }

    private var hasCancellableTasks: Bool {
        downloadManager.tasks.contains {
            $0.status == .queued || $0.status == .resolving || $0.status == .downloading
        }
    }

    private var hasFailedTasks: Bool {
        downloadManager.tasks.contains { $0.status == .failed }
    }

    private var hasClearableTasks: Bool {
        downloadManager.tasks.contains { $0.status == .finished || $0.status == .cancelled }
    }

    private var emptyStateImage: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? filter.systemImage : "magnifyingglass"
    }

    private var emptyStateMessage: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? filter.emptyMessage
            : "No downloads match your search."
    }
}

private struct TaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    let item: DownloadTaskItem
    let retry: () -> Void
    let resume: () -> Void
    let pause: () -> Void
    let cancel: () -> Void
    let promote: () -> Void
    let delete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Summary") {
                    LabeledContent("Status") {
                        Label(item.status.title, systemImage: statusImage)
                            .foregroundStyle(statusTint)
                    }
                    LabeledContent("Template", value: item.templateName)
                    LabeledContent("Mode", value: item.mode.title)
                    if let fileName = item.fileName {
                        LabeledContent("File Name", value: fileName)
                    }
                    LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let finishedAt = item.finishedAt {
                        LabeledContent("Finished", value: finishedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if item.status == .downloading {
                        ProgressView(value: item.progress)
                        Text(byteSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if item.bytesPerSecond > 0 {
                            LabeledContent("Speed", value: speedString(item.bytesPerSecond))
                        }
                        if let estimatedRemainingSeconds = item.estimatedRemainingSeconds,
                           estimatedRemainingSeconds.isFinite {
                            LabeledContent("Remaining", value: durationString(estimatedRemainingSeconds))
                        }
                    }

                    Button {
                        UIPasteboard.general.string = diagnosticSummary
                    } label: {
                        Label("Copy Details", systemImage: "doc.on.doc")
                    }
                }

                Section("Links") {
                    CopyableTextRow(title: "Source", value: item.sourceURL)
                    if let resolvedURL = item.resolvedURL {
                        CopyableTextRow(title: "Resolved", value: resolvedURL)
                    }
                }

                if let arguments = item.effectiveArguments {
                    Section("Arguments") {
                        CopyableTextRow(title: item.effectiveArgumentsTitle ?? "yt-dlp", value: arguments)
                    }
                }

                if let message = item.message {
                    Section(item.status == .failed ? "Error" : "Message") {
                        CopyableTextRow(title: item.status.title, value: message)
                            .foregroundStyle(item.status == .failed ? .red : .primary)
                    }
                }

                if let localPath = item.localPath {
                    Section("File") {
                        CopyableTextRow(title: "Path", value: localPath)

                        let fileURL = URL(fileURLWithPath: localPath)
                        Button {
                            previewURL = fileURL
                        } label: {
                            Label("Preview", systemImage: "eye")
                        }

                        ShareLink(item: fileURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section {
                    if item.status == .paused {
                        Button {
                            resume()
                            dismiss()
                        } label: {
                            Label("Resume", systemImage: "play")
                        }
                    }

                    if item.status == .downloading {
                        Button {
                            pause()
                            dismiss()
                        } label: {
                            Label("Pause", systemImage: "pause")
                        }
                    }

                    if item.status == .failed || item.status == .cancelled {
                        Button {
                            retry()
                            dismiss()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }

                    if item.status == .queued || item.status == .resolving || item.status == .paused {
                        if item.status == .queued {
                            Button {
                                promote()
                                dismiss()
                            } label: {
                                Label("Make Next", systemImage: "arrow.up.to.line")
                            }
                        }

                        Button(role: .destructive) {
                            cancel()
                            dismiss()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }

                    Button(role: .destructive) {
                        delete()
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var statusImage: String {
        switch item.status {
        case .queued: "clock"
        case .resolving: "server.rack"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .queued, .resolving: .secondary
        case .downloading: .blue
        case .paused: .orange
        case .finished: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private var byteSummary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: item.receivedBytes)
        guard item.totalBytes > 0 else { return received }
        let total = formatter.string(fromByteCount: item.totalBytes)
        return "\(received) of \(total)"
    }

    private func speedString(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: clampedByteCount(bytesPerSecond)))/s"
    }

    private func clampedByteCount(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        return Int64(min(max(value, 0), Double(Int64.max)))
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let clampedSeconds = max(Int(seconds.rounded()), 0)
        let hours = clampedSeconds / 3_600
        let minutes = (clampedSeconds % 3_600) / 60
        let seconds = clampedSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private var diagnosticSummary: String {
        var lines = [
            "Title: \(item.title)",
            "Status: \(item.status.title)",
            "Template: \(item.templateName)",
            "Mode: \(item.mode.title)",
            "Source: \(item.sourceURL)"
        ]

        if let resolvedURL = item.resolvedURL {
            lines.append("Resolved: \(resolvedURL)")
        }
        if let arguments = item.effectiveArguments {
            let title = item.effectiveArgumentsTitle ?? "yt-dlp"
            lines.append("Arguments (\(title)): \(arguments)")
        }
        if let fileName = item.fileName {
            lines.append("File: \(fileName)")
        }
        if item.bytesPerSecond > 0 {
            lines.append("Speed: \(speedString(item.bytesPerSecond))")
        }
        if let estimatedRemainingSeconds = item.estimatedRemainingSeconds,
           estimatedRemainingSeconds.isFinite {
            lines.append("Remaining: \(durationString(estimatedRemainingSeconds))")
        }
        if let localPath = item.localPath {
            lines.append("Local path: \(localPath)")
        }
        if let message = item.message {
            lines.append("Message: \(message)")
        }

        return lines.joined(separator: "\n")
    }
}

private struct CopyableTextRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

private enum DownloadFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case done
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray"
        case .active: "arrow.down.circle"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Paste a link to start a new download."
        case .active: "No downloads are running."
        case .done: "Finished downloads will appear here."
        case .failed: "Failed downloads will appear here."
        }
    }

    func includes(_ status: DownloadStatus) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            status == .queued || status == .resolving || status == .downloading || status == .paused
        case .done:
            status == .finished
        case .failed:
            status == .failed || status == .cancelled
        }
    }
}
