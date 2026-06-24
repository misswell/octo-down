import SwiftUI

struct RootView: View {
    @EnvironmentObject private var incomingLinkInbox: IncomingLinkInbox
    @State private var selectedTab: RootTab = .new

    var body: some View {
        TabView(selection: $selectedTab) {
            NewDownloadView()
                .tabItem {
                    Label("New", systemImage: "plus.circle")
                }
                .tag(RootTab.new)

            DownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .tag(RootTab.downloads)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "folder")
                }
                .tag(RootTab.library)

            TemplatesView()
                .tabItem {
                    Label("Templates", systemImage: "slider.horizontal.3")
                }
                .tag(RootTab.templates)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(RootTab.settings)
        }
        .onChange(of: incomingLinkInbox.pending) { _, incoming in
            if incoming != nil {
                selectedTab = .new
            }
        }
    }
}

private enum RootTab: Hashable {
    case new
    case downloads
    case library
    case templates
    case settings
}
