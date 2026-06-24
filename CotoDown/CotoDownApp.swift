import SwiftUI

@main
struct CotoDownApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings = AppSettings()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var incomingLinkInbox = IncomingLinkInbox()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(downloadManager)
                .environmentObject(incomingLinkInbox)
                .onOpenURL { url in
                    incomingLinkInbox.receive(url)
                }
        }
    }
}
