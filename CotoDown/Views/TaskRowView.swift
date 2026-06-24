import SwiftUI

struct TaskRowView: View {
    let item: DownloadTaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(tintColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(item.sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(item.status.title)
                    .font(.caption)
                    .foregroundStyle(tintColor)
            }

            if item.status == .downloading {
                ProgressView(value: item.progress)
                Text(byteSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let arguments = item.effectiveArguments {
                Label(arguments, systemImage: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let message = item.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(item.status == .failed ? .red : .secondary)
            }

            if let localPath = item.localPath {
                HStack(spacing: 12) {
                    Text(localPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)

                    ShareLink(item: URL(fileURLWithPath: localPath)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share downloaded file")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var iconName: String {
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

    private var tintColor: Color {
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
        let sizeText: String
        if item.totalBytes > 0 {
            let total = formatter.string(fromByteCount: item.totalBytes)
            sizeText = "\(received) of \(total)"
        } else {
            sizeText = received
        }

        var parts = [sizeText]
        if item.bytesPerSecond > 0 {
            parts.append("\(formatter.string(fromByteCount: clampedByteCount(item.bytesPerSecond)))/s")
        }
        if let estimatedRemainingSeconds = item.estimatedRemainingSeconds, estimatedRemainingSeconds.isFinite {
            parts.append("\(durationString(estimatedRemainingSeconds)) left")
        }
        return parts.joined(separator: " - ")
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
}
