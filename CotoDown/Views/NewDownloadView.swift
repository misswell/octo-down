import SwiftUI

struct NewDownloadView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var incomingLinkInbox: IncomingLinkInbox

    @State private var urlString = ""
    @State private var selectedTemplateID: DownloadTemplate.ID?
    @State private var customArguments = ""
    @State private var preferredFileName = ""
    @State private var showsAdvancedOptions = false
    @State private var selectedFormatOption: FormatOption = .templateDefault
    @State private var embedsMetadataAndThumbnail = false
    @State private var writesSubtitles = false
    @State private var downloadsPlaylist = false
    @State private var playlistStart = 1
    @State private var playlistItemCount = 20
    @State private var previewStatus: LinkPreviewStatus = .idle

    private var templates: [DownloadTemplate] {
        settings.templates.isEmpty ? AppSettings.defaultTemplates : settings.templates
    }

    var selectedTemplate: DownloadTemplate {
        templates.first { $0.id == selectedTemplateID } ?? templates[0]
    }

    private var effectiveTemplate: DownloadTemplate {
        var template = selectedTemplate
        template.mode = effectiveMode
        return template
    }

    private var effectiveMode: MediaMode {
        if downloadsPlaylist {
            return .playlist
        }
        if selectedFormatOption == .audioM4A {
            return .audio
        }
        return selectedTemplate.mode
    }

    private var pendingURLStrings: [String] {
        Self.urlStrings(in: urlString)
    }
    
    private var hasResolver: Bool {
        !settings.resolverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste video, audio, or file URLs", text: $urlString, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(3...8)

                    PasteButton(payloadType: String.self) { values in
                        if let pasted = values.first {
                            urlString = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                
                // Download status indicator
                if let firstURL = pendingURLStrings.first {
                    Section("Status") {
                        Label(
                            BackendResolver.downloadStatusMessage(for: firstURL, hasResolver: hasResolver),
                            systemImage: statusIcon(for: firstURL)
                        )
                        .font(.footnote)
                        .foregroundStyle(statusColor(for: firstURL))
                    }
                }

                Section("Mode") {
                    Picker("Template", selection: $selectedTemplateID) {
                        ForEach(templates) { template in
                            Label(template.name, systemImage: iconName(for: template.mode)).tag(Optional(template.id))
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(effectiveMode.title, systemImage: iconName(for: effectiveMode))
                            .font(.headline)
                        Text(selectedTemplate.arguments.isEmpty ? "No arguments" : selectedTemplate.arguments)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }

                Section("Quick Options") {
                    Picker("Format", selection: $selectedFormatOption) {
                        ForEach(FormatOption.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Metadata and thumbnail", isOn: $embedsMetadataAndThumbnail)
                    Toggle("Subtitles", isOn: $writesSubtitles)
                    Toggle("Playlist", isOn: $downloadsPlaylist)

                    if downloadsPlaylist {
                        Stepper("Start: \(playlistStart)", value: $playlistStart, in: 1...999)
                        Stepper("Items: \(playlistItemCount)", value: $playlistItemCount, in: 1...100)
                    }

                    if let quickArguments {
                        Text(quickArguments)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if effectiveMode != selectedTemplate.mode {
                        Label("Quick options set mode to \(effectiveMode.title).", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Preview") {
                    Button {
                        previewLink()
                    } label: {
                        Label("Preview Link", systemImage: "info.circle")
                    }
                    .disabled(!canPreviewLink)

                    switch previewStatus {
                    case .idle:
                        EmptyView()
                    case .loading:
                        ProgressView("Resolving link...")
                    case .loaded(let info):
                        LinkPreviewSummary(info: info, onUseFormat: usePreviewFormat)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Advanced") {
                    TextField("File name (optional)", text: $preferredFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Override arguments", isOn: $showsAdvancedOptions)

                    if showsAdvancedOptions {
                        TextField("yt-dlp arguments for this download", text: $customArguments, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...6)
                            .font(.system(.footnote, design: .monospaced))

                        Text("This only affects the next download. Leave empty to use the selected template.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        let argumentOverride = resolvedArgumentOverride
                        downloadManager.enqueue(
                            sourceURLs: pendingURLStrings,
                            template: effectiveTemplate,
                            settings: settings,
                            argumentOverride: argumentOverride,
                            preferredFileName: preferredFileName
                        )
                        urlString = ""
                        customArguments = ""
                        preferredFileName = ""
                        showsAdvancedOptions = false
                        resetQuickOptions()
                    } label: {
                        Label(startButtonTitle, systemImage: "arrow.down.to.line")
                    }
                    .disabled(pendingURLStrings.isEmpty)
                }

                // Help section
                Section("Supported Platforms") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Direct Links (mp4, mp3, pdf, etc.)", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                        Text("Download immediately - no setup needed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Divider()
                        
                        Label("YouTube, Bilibili, Douyin, Xiaohongshu, TikTok, Vimeo, Twitter/X, Instagram", systemImage: "play.rectangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                        Text("Resolved locally on your device - no server needed!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Divider()
                        
                        Label("How it works", systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Uses built-in web technology to extract video URLs directly on your iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("coto down")
            .onAppear {
                selectedTemplateID = selectedTemplateID ?? templates.first?.id
                if let incoming = incomingLinkInbox.pending {
                    apply(incoming)
                }
            }
            .onChange(of: incomingLinkInbox.pending) { _, incoming in
                if let incoming {
                    apply(incoming)
                }
            }
            .onChange(of: urlString) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: selectedTemplateID) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: selectedFormatOption) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: embedsMetadataAndThumbnail) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: writesSubtitles) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: downloadsPlaylist) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: playlistStart) { _, _ in
                previewStatus = .idle
            }
            .onChange(of: playlistItemCount) { _, _ in
                previewStatus = .idle
            }
        }
    }

    private func apply(_ incoming: IncomingDownload) {
        let template = template(named: incoming.templateName)
        selectedTemplateID = template.id

        if incoming.startsImmediately {
            downloadManager.enqueue(
                sourceURLs: incoming.urlStrings,
                template: template,
                settings: settings,
                argumentOverride: incoming.argumentOverride,
                preferredFileName: incoming.preferredFileName
            )
            urlString = ""
            customArguments = ""
            preferredFileName = ""
            showsAdvancedOptions = false
            resetQuickOptions()
        } else {
            urlString = incoming.urlStrings.joined(separator: "\n")
            preferredFileName = incoming.preferredFileName ?? ""
            let cleanArguments = incoming.argumentOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanArguments, !cleanArguments.isEmpty {
                customArguments = cleanArguments
                showsAdvancedOptions = true
                resetQuickOptions()
            }
        }

        incomingLinkInbox.clear(incoming)
    }

    private func template(named name: String?) -> DownloadTemplate {
        guard let name,
              let matchingTemplate = templates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else {
            return selectedTemplate
        }

        return matchingTemplate
    }

    private func iconName(for mode: MediaMode) -> String {
        switch mode {
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .playlist: "list.bullet.rectangle"
        case .custom: "terminal"
        }
    }

    private func statusIcon(for url: String) -> String {
        if BackendResolver.isDirectDownloadURL(url) {
            return "checkmark.circle.fill"
        }
        if BackendResolver.needsResolver(url) {
            return hasResolver ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill"
        }
        return "arrow.down.circle"
    }

    private func statusColor(for url: String) -> Color {
        if BackendResolver.isDirectDownloadURL(url) {
            return .green
        }
        if BackendResolver.needsResolver(url) {
            return hasResolver ? .blue : .orange
        }
        return .secondary
    }

    private var startButtonTitle: String {
        pendingURLStrings.count > 1 ? "Start \(pendingURLStrings.count) Downloads" : "Start Download"
    }

    private var canPreviewLink: Bool {
        pendingURLStrings.count == 1
            && previewStatus != .loading
            && !settings.resolverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func previewLink() {
        guard let urlString = pendingURLStrings.first else { return }
        previewStatus = .loading

        let template = effectiveTemplate
        let argumentOverride = resolvedArgumentOverride
        Task { @MainActor in
            do {
                let info = try await BackendResolver().info(
                    sourceURL: urlString,
                    template: template,
                    argumentOverride: argumentOverride,
                    endpoint: settings.resolverEndpoint,
                    token: settings.resolverToken
                )
                previewStatus = .loaded(info)
            } catch {
                previewStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func usePreviewFormat(_ format: ResolvedFormatInfo) {
        var arguments = [format.downloadArguments]
        if let optionArguments = quickArguments(includeFormat: false) {
            arguments.append(optionArguments)
        }
        customArguments = arguments.joined(separator: " ")
        showsAdvancedOptions = true
        resetQuickOptions()
    }

    private var resolvedArgumentOverride: String? {
        if showsAdvancedOptions {
            return Self.cleanArgumentOverride(customArguments)
        }

        return quickArguments
    }

    private var quickArguments: String? {
        quickArguments(includeFormat: true)
    }

    private func quickArguments(includeFormat: Bool) -> String? {
        var arguments: [String] = []

        if includeFormat, let formatArguments = selectedFormatOption.arguments {
            arguments.append(formatArguments)
        }
        if embedsMetadataAndThumbnail {
            arguments.append("--embed-thumbnail --embed-metadata")
        }
        if writesSubtitles {
            arguments.append("--write-subs --write-auto-subs --sub-langs all,-live_chat --embed-subs")
        }
        if downloadsPlaylist {
            let playlistEnd = playlistStart + playlistItemCount - 1
            arguments.append("--yes-playlist --playlist-start \(playlistStart) --playlist-end \(playlistEnd)")
        }

        let joined = arguments.joined(separator: " ")
        return Self.cleanArgumentOverride(joined)
    }

    private func resetQuickOptions() {
        selectedFormatOption = .templateDefault
        embedsMetadataAndThumbnail = false
        writesSubtitles = false
        downloadsPlaylist = false
        playlistStart = 1
        playlistItemCount = 20
    }

    private nonisolated static func cleanArgumentOverride(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private nonisolated static func urlStrings(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var urls: [String] = []
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        detector?.enumerateMatches(in: trimmed, options: [], range: range) { match, _, _ in
            guard let urlString = match?.url?.absoluteString else { return }
            urls.append(urlString)
        }

        if urls.isEmpty, URL(string: trimmed) != nil {
            urls.append(trimmed)
        }

        var seen = Set<String>()
        return urls.filter { urlString in
            guard !seen.contains(urlString) else { return false }
            seen.insert(urlString)
            return true
        }
    }
}

private enum LinkPreviewStatus: Equatable {
    case idle
    case loading
    case loaded(ResolvedLinkInfo)
    case failed(String)
}

private struct LinkPreviewSummary: View {
    let info: ResolvedLinkInfo
    let onUseFormat: (ResolvedFormatInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnailURL {
                PreviewThumbnailView(url: thumbnailURL)
            }

            Label(info.title ?? "Untitled", systemImage: "play.rectangle")
                .font(.headline)

            if let uploader = info.uploader {
                Label(uploader, systemImage: "person")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if let extractor = info.extractor {
                    Label(extractor, systemImage: "globe")
                }
                if let durationSeconds = info.durationSeconds, durationSeconds.isFinite {
                    Label(durationString(durationSeconds), systemImage: "clock")
                }
                if let entryCount = info.entryCount, entryCount > 0 {
                    Label("\(entryCount) items", systemImage: "list.bullet.rectangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let webpageURL = info.webpageURL {
                Text(webpageURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let formats = info.formats, !formats.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Formats")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    ForEach(Array(formats.prefix(8))) { format in
                        LinkPreviewFormatRow(format: format, onUseFormat: onUseFormat)
                    }

                    if formats.count > 8 {
                        Text("+ \(formats.count - 8) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var thumbnailURL: URL? {
        guard let thumbnail = info.thumbnail else { return nil }
        return URL(string: thumbnail)
    }

    private func durationString(_ seconds: Double) -> String {
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

private struct LinkPreviewFormatRow: View {
    let format: ResolvedFormatInfo
    let onUseFormat: (ResolvedFormatInfo) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote)
                    .fontWeight(.medium)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                onUseFormat(format)
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Use format \(format.id)")
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        var parts = [format.id]
        if let resolution = format.resolution {
            parts.append(resolution)
        } else if let note = format.note {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        var parts: [String] = []

        if let fileExtension = format.fileExtension {
            parts.append(fileExtension.uppercased())
        }
        if format.hasVideo && format.hasAudio {
            parts.append("video + audio")
        } else if format.hasVideo {
            parts.append("video")
        } else if format.hasAudio {
            parts.append("audio")
        }
        if let bitrate = format.bitrateKbps {
            parts.append("\(Int(bitrate.rounded())) kbps")
        }
        if let filesizeBytes = format.filesizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: filesizeBytes, countStyle: .file))
        }
        if let fps = format.fps, fps > 0 {
            parts.append("\(Int(fps.rounded())) fps")
        }

        return parts.joined(separator: " · ")
    }
}

private struct PreviewThumbnailView: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                placeholder
            case .empty:
                placeholder
                    .overlay {
                        ProgressView()
                    }
            @unknown default:
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}

private enum FormatOption: String, CaseIterable, Identifiable {
    case templateDefault
    case best
    case mp4
    case upTo1080p
    case upTo720p
    case audioM4A

    var id: String { rawValue }

    var title: String {
        switch self {
        case .templateDefault: "Template default"
        case .best: "Best available"
        case .mp4: "Compatible MP4"
        case .upTo1080p: "Up to 1080p"
        case .upTo720p: "Up to 720p"
        case .audioM4A: "Audio M4A"
        }
    }

    var systemImage: String {
        switch self {
        case .templateDefault: "slider.horizontal.3"
        case .best: "sparkles.tv"
        case .mp4: "play.rectangle"
        case .upTo1080p, .upTo720p: "rectangle.compress.vertical"
        case .audioM4A: "waveform"
        }
    }

    var arguments: String? {
        switch self {
        case .templateDefault:
            nil
        case .best:
            "-f bv*+ba/b"
        case .mp4:
            "-f b[ext=mp4]/bv*+ba/b --merge-output-format mp4"
        case .upTo1080p:
            "-f bv*[height<=1080]+ba/b[height<=1080]/b --merge-output-format mp4"
        case .upTo720p:
            "-f bv*[height<=720]+ba/b[height<=720]/b --merge-output-format mp4"
        case .audioM4A:
            "-x --audio-format m4a"
        }
    }
}
