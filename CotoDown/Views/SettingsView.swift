import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var resolverStatus: ResolverStatus = .idle
    @State private var exportedConfigurationURL: URL?
    @State private var isImportingConfiguration = false
    @State private var configurationStatus: ConfigurationStatus = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section("Resolver") {
                    TextField("https://your-server.example/resolve", text: $settings.resolverEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Picker("Delivery", selection: $settings.resolverDelivery) {
                        ForEach(ResolverDelivery.allCases) { delivery in
                            Text(delivery.title).tag(delivery)
                        }
                    }

                    SecureField("Resolver token (optional)", text: $settings.resolverToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text(settings.resolverDelivery.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        testResolver()
                    } label: {
                        Label("Test Resolver", systemImage: "network")
                    }
                    .disabled(resolverStatus == .checking)

                    if resolverStatus != .idle {
                        Label(resolverStatus.message, systemImage: resolverStatus.systemImage)
                            .font(.footnote)
                            .foregroundStyle(resolverStatus.tint)
                    }

                    Text("Fallback: External resolver for platforms not supported by local resolution. Most platforms work without this.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Files") {
                    Stepper(
                        "Concurrent downloads: \(settings.maxConcurrentDownloads)",
                        value: $settings.maxConcurrentDownloads,
                        in: AppSettings.maxConcurrentDownloadsRange
                    )
                    .onChange(of: settings.maxConcurrentDownloads) { _, _ in
                        downloadManager.updateQueuePolicy(settings: settings)
                    }

                    Label("Completed downloads are stored in Documents/Coto Down Downloads.", systemImage: "folder")
                    Label("File sharing is enabled for Finder and the Files app.", systemImage: "iphone.and.arrow.forward")
                    Label("Downloads use an iOS background session when possible.", systemImage: "arrow.down.app")
                    Text("Queued items start automatically as active downloads finish or pause.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cookies") {
                    TextEditor(text: $settings.platformCookies)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .frame(minHeight: 120)

                    Button(role: .destructive) {
                        settings.platformCookies = ""
                    } label: {
                        Label("Clear Cookies", systemImage: "trash")
                    }
                    .disabled(settings.platformCookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Notifications") {
                    Toggle("Download alerts", isOn: $settings.notificationsEnabled)
                        .onChange(of: settings.notificationsEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    let granted = await NotificationCenterService.requestAuthorization()
                                    if !granted {
                                        settings.notificationsEnabled = false
                                    }
                                }
                            }
                        }

                    Text("Receive a local alert when a download finishes or fails.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Configuration") {
                    Button {
                        exportConfiguration()
                    } label: {
                        Label("Export Configuration", systemImage: "square.and.arrow.up")
                    }

                    if let exportedConfigurationURL {
                        ShareLink(item: exportedConfigurationURL) {
                            Label("Share Exported File", systemImage: "doc")
                        }
                    }

                    Button {
                        isImportingConfiguration = true
                    } label: {
                        Label("Import Configuration", systemImage: "square.and.arrow.down")
                    }

                    if configurationStatus != .idle {
                        Label(configurationStatus.message, systemImage: configurationStatus.systemImage)
                            .font(.footnote)
                            .foregroundStyle(configurationStatus.tint)
                    }
                }

                Section("About") {
                    LabeledContent("Name", value: "coto down")
                    LabeledContent("Platform", value: "iOS 17+")
                    Link(destination: URL(string: "https://github.com/JunkFood02/Seal")!) {
                        Label("Inspired by Seal", systemImage: "link")
                    }
                }
            }
            .navigationTitle("Settings")
            .fileImporter(
                isPresented: $isImportingConfiguration,
                allowedContentTypes: [.json]
            ) { result in
                importConfiguration(result)
            }
        }
    }

    private func testResolver() {
        resolverStatus = .checking
        Task {
            do {
                try await ResolverHealthService().check(
                    endpoint: settings.resolverEndpoint,
                    token: settings.resolverToken
                )
                resolverStatus = .healthy
            } catch {
                resolverStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func exportConfiguration() {
        do {
            exportedConfigurationURL = try AppConfigurationService.exportURL(
                for: settings.exportConfiguration()
            )
            configurationStatus = .exported
        } catch {
            configurationStatus = .failed(error.localizedDescription)
        }
    }

    private func importConfiguration(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let configuration = try AppConfigurationService.importConfiguration(from: url)
            settings.apply(configuration: configuration)
            downloadManager.updateQueuePolicy(settings: settings)
            exportedConfigurationURL = nil
            configurationStatus = .imported
        } catch {
            configurationStatus = .failed(error.localizedDescription)
        }
    }
}

private enum ResolverStatus: Equatable {
    case idle
    case checking
    case healthy
    case failed(String)

    var message: String {
        switch self {
        case .idle: ""
        case .checking: "Checking resolver..."
        case .healthy: "Resolver is healthy."
        case .failed(let message): message
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .checking: "clock"
        case .healthy: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .checking: .secondary
        case .healthy: .green
        case .failed: .red
        }
    }
}

private enum ConfigurationStatus: Equatable {
    case idle
    case exported
    case imported
    case failed(String)

    var message: String {
        switch self {
        case .idle: ""
        case .exported: "Configuration export is ready to share."
        case .imported: "Configuration imported."
        case .failed(let message): message
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .exported: "checkmark.circle"
        case .imported: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .exported, .imported: .green
        case .failed: .red
        }
    }
}
