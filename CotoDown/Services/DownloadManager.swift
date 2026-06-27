import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var tasks: [DownloadTaskItem] = []

    static let backgroundSessionIdentifier = "com.coto.down.downloads.background"

    private let storageKey = "downloadTasks"
    private let taskMapKey = "backgroundTaskMap"
    private var session: URLSession!
    private var runningTasks: [UUID: URLSessionDownloadTask] = [:]
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]
    private var dashTasks: [UUID: Task<Void, Never>] = [:]
    private var taskIDMap: [Int: UUID] = [:]
    private let resolver = VideoResolverService()
    private var maxConcurrentDownloads = AppSettings.maxConcurrentDownloadsPreference
    private static var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private struct RunningTaskDescription: Codable {
        var id: UUID
        var fileName: String?
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        load()
        loadTaskMap()
        restoreRunningTasks()
    }

    static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletionHandlers[identifier] = handler
    }

    func updateQueuePolicy(settings: AppSettings) {
        maxConcurrentDownloads = AppSettings.clampedMaxConcurrentDownloads(settings.maxConcurrentDownloads)
        processQueue()
    }

    func enqueue(
        sourceURL: String,
        template: DownloadTemplate,
        settings: AppSettings,
        argumentOverride: String? = nil,
        preferredFileName: String? = nil
    ) {
        enqueue(
            sourceURLs: [sourceURL],
            template: template,
            settings: settings,
            argumentOverride: argumentOverride,
            preferredFileName: preferredFileName
        )
    }

    func enqueue(
        sourceURLs: [String],
        template: DownloadTemplate,
        settings: AppSettings,
        argumentOverride: String? = nil,
        preferredFileName: String? = nil
    ) {
        let cleanArgumentOverride = Self.cleanArgumentOverride(argumentOverride)
        let cleanPreferredFileName = Self.cleanPreferredFileName(preferredFileName)
        let newItems = sourceURLs.compactMap { sourceURL -> DownloadTaskItem? in
            let cleanURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(string: cleanURL) != nil else { return nil }

            // Note: VideoResolverService will try local resolution first,
            // then fall back to external resolver if configured.
            // No need to skip URLs here.

            return DownloadTaskItem(
                sourceURL: cleanURL,
                title: cleanPreferredFileName.map(Self.titleFromFileName) ?? titleFromURL(cleanURL),
                fileName: cleanPreferredFileName,
                mode: template.mode,
                templateName: template.name,
                templateArguments: template.arguments,
                resolverEndpoint: settings.resolverEndpoint,
                resolverDelivery: settings.resolverDelivery,
                resolverToken: settings.resolverToken,
                argumentOverride: cleanArgumentOverride,
                status: .queued
            )
        }

        guard !newItems.isEmpty else { return }

        // Show warning if some URLs were skipped
        let skippedCount = sourceURLs.count - newItems.count
        if skippedCount > 0 {
            NotificationCenterService.notifyDownloadFailed(
                title: "Skipped \(skippedCount) link(s)",
                message: "YouTube, Vimeo, etc. require a resolver service. Only direct download links (mp4, mp3, etc.) work without resolver."
            )
        }

        updateQueuePolicy(settings: settings)
        tasks.insert(contentsOf: newItems, at: 0)
        save()
        processQueue()
    }

    func retry(_ item: DownloadTaskItem, settings: AppSettings) {
        updateQueuePolicy(settings: settings)
        retryWithoutScheduling(item, settings: settings)
        processQueue()
    }

    func retryFailed(settings: AppSettings) {
        let failedItems = tasks.filter { $0.status == .failed }
        guard !failedItems.isEmpty else { return }

        updateQueuePolicy(settings: settings)
        for item in failedItems {
            retryWithoutScheduling(item, settings: settings)
        }
        processQueue()
    }

    private func retryWithoutScheduling(_ item: DownloadTaskItem, settings: AppSettings) {
        removeRunningTask(id: item.id)
        let template = settings.template(named: item.templateName)
        update(item.id) {
            $0.status = .queued
            $0.progress = 0
            $0.receivedBytes = 0
            $0.totalBytes = 0
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
            $0.message = nil
            $0.finishedAt = nil
            $0.templateArguments = template.arguments
            $0.resolverEndpoint = settings.resolverEndpoint
            $0.resolverDelivery = settings.resolverDelivery
            $0.resolverToken = settings.resolverToken
        }
    }

    func cancel(_ item: DownloadTaskItem) {
        cancelWithoutScheduling(item)
        processQueue()
    }

    func pause(_ item: DownloadTaskItem) {
        guard item.status == .downloading else { return }

        if let hlsTask = hlsTasks[item.id] {
            hlsTask.cancel()
            hlsTasks[item.id] = nil
            update(item.id) {
                $0.status = .paused
                $0.message = "Paused; HLS resume is unavailable"
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }
            processQueue()
            return
        }

        if let dashTask = dashTasks[item.id] {
            dashTask.cancel()
            dashTasks[item.id] = nil
            update(item.id) {
                $0.status = .paused
                $0.message = "Paused; DASH merge resume is unavailable"
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }
            processQueue()
            return
        }

        guard let task = runningTasks[item.id] else { return }

        update(item.id) {
            $0.status = .paused
            $0.message = "Pausing..."
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
        }

        task.cancel(byProducingResumeData: { [weak self] resumeData in
            guard let self else { return }
            Task { @MainActor in
                self.runningTasks[item.id] = nil
                self.taskIDMap[task.taskIdentifier] = nil
                self.saveTaskMap()
                self.update(item.id) {
                    $0.status = .paused
                    $0.message = resumeData == nil ? "Paused; resume data unavailable" : "Paused"
                    $0.bytesPerSecond = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.lastProgressAt = nil
                    $0.resumeData = resumeData
                }
                self.processQueue()
            }
        })
    }

    func resume(_ item: DownloadTaskItem, settings: AppSettings) {
        guard item.status == .paused else { return }

        updateQueuePolicy(settings: settings)
        if item.resumeData != nil {
            update(item.id) {
                $0.status = .queued
                $0.message = "Queued to resume"
            }
            processQueue()
        } else {
            retry(item, settings: settings)
        }
    }

    func pauseAll() {
        for item in tasks where item.status == .downloading {
            pause(item)
        }
    }

    func resumeAll(settings: AppSettings) {
        for item in tasks where item.status == .paused {
            resume(item, settings: settings)
        }
    }

    func cancelActive() {
        let cancellableItems = tasks.filter { item in
            item.status == .queued || item.status == .resolving || item.status == .downloading
        }
        guard !cancellableItems.isEmpty else { return }

        for item in cancellableItems {
            cancelWithoutScheduling(item)
        }
    }

    func promoteQueued(_ item: DownloadTaskItem) {
        guard item.status == .queued,
              let index = tasks.firstIndex(where: { $0.id == item.id })
        else { return }

        let promoted = tasks.remove(at: index)
        let insertionIndex = tasks.firstIndex { $0.status == .queued } ?? tasks.count
        tasks.insert(promoted, at: insertionIndex)
        update(promoted.id) {
            $0.message = "Next in queue"
        }
        processQueue()
    }

    private func cancelWithoutScheduling(_ item: DownloadTaskItem) {
        removeRunningTask(id: item.id)
        update(item.id) {
            $0.status = .cancelled
            $0.message = "Cancelled"
            $0.finishedAt = Date()
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
        }
    }

    func delete(_ item: DownloadTaskItem) {
        removeRunningTask(id: item.id)
        if let localPath = item.localPath {
            try? FileManager.default.removeItem(atPath: localPath)
        }
        tasks.removeAll { $0.id == item.id }
        save()
        processQueue()
    }

    func clearFinished() {
        tasks.removeAll { $0.status == .finished || $0.status == .cancelled }
        save()
    }

    func clearFailed() {
        tasks.removeAll { $0.status == .failed }
        save()
    }

    private func processQueue() {
        while activeTaskCount < maxConcurrentDownloads,
              let nextItem = tasks.first(where: { $0.status == .queued }) {
            startQueuedTask(nextItem)
        }
    }

    private var activeTaskCount: Int {
        let activeStatusIDs = tasks
            .filter { $0.status == .resolving || $0.status == .downloading }
            .map(\.id)
        return Set(activeStatusIDs).union(runningTasks.keys).union(hlsTasks.keys).union(dashTasks.keys).count
    }

    private func startQueuedTask(_ item: DownloadTaskItem) {
        if let resumeData = item.resumeData {
            startDownload(for: item.id, resumeData: resumeData, fileName: item.fileName)
            return
        }

        if let resolvedURL = item.resolvedURL {
            if let audioURL = item.resolvedAudioURL {
                startDASHDownload(
                    for: item.id,
                    videoURLString: resolvedURL,
                    audioURLString: audioURL,
                    pageURLString: item.sourceURL,
                    fileName: item.fileName,
                    title: item.title
                )
            } else if Self.isDASHManifestURL(resolvedURL) {
                startDASHManifestDownload(for: item.id, manifestURLString: resolvedURL, fileName: item.fileName, title: item.title)
            } else if Self.isHLSPlaylistURL(resolvedURL) {
                startHLSDownload(for: item.id, playlistURLString: resolvedURL, fileName: item.fileName, title: item.title)
            } else {
                startDownload(for: item.id, resolvedURL: resolvedURL, fileName: item.fileName, title: item.title)
            }
            return
        }

        if Self.isHLSPlaylistURL(item.sourceURL) {
            startHLSDownload(for: item.id, playlistURLString: item.sourceURL, fileName: item.fileName, title: item.title)
            return
        }

        if Self.isDASHManifestURL(item.sourceURL) {
            startDASHManifestDownload(for: item.id, manifestURLString: item.sourceURL, fileName: item.fileName, title: item.title)
            return
        }

        if Self.isDirectDownloadURL(item.sourceURL) {
            startDownload(for: item.id, resolvedURL: item.sourceURL, fileName: item.fileName, title: item.title)
            return
        }

        // VideoResolverService will handle both local and external resolution
        startResolving(item)
    }

    private func startResolving(_ item: DownloadTaskItem) {
        update(item.id) {
            $0.status = .resolving
            $0.message = "Resolving with \(item.templateName)"
        }

        let template = DownloadTemplate(
            name: item.templateName,
            mode: item.mode,
            arguments: item.templateArguments ?? ""
        )
        let endpoint = item.resolverEndpoint ?? ""
        let token = item.resolverToken ?? ""
        let delivery = item.resolverDelivery ?? .direct

        Task {
            await resolveThenDownload(
                itemID: item.id,
                sourceURL: item.sourceURL,
                template: template,
                endpoint: endpoint,
                token: token,
                delivery: delivery,
                argumentOverride: item.argumentOverrideArguments
            )
        }
    }

    private func resolveThenDownload(
        itemID: UUID,
        sourceURL: String,
        template: DownloadTemplate,
        endpoint: String,
        token: String,
        delivery: ResolverDelivery,
        argumentOverride: String?
    ) async {
        do {
            let response = try await resolver.resolve(
                url: sourceURL,
                template: template,
                argumentOverride: argumentOverride,
                endpoint: endpoint,
                token: token,
                delivery: delivery
            )
            let mediaItems = try response.mediaItems()
            guard let firstItem = mediaItems.first else {
                throw BackendResolverError.invalidResolvedURL
            }

            guard tasks.first(where: { $0.id == itemID })?.status == .resolving else {
                processQueue()
                return
            }

            let preferredFileName = tasks.first(where: { $0.id == itemID })?.fileName
            let resolvedFileName = preferredFileName ?? firstItem.filename
            if let audioURL = firstItem.audioURL {
                startDASHDownload(
                    for: itemID,
                    videoURLString: firstItem.url,
                    audioURLString: audioURL,
                    pageURLString: sourceURL,
                    fileName: resolvedFileName,
                    title: firstItem.title
                )
            } else if Self.isHLSPlaylistURL(firstItem.url) {
                startHLSDownload(
                    for: itemID,
                    playlistURLString: firstItem.url,
                    fileName: resolvedFileName,
                    title: firstItem.title
                )
            } else {
                startDownload(
                    for: itemID,
                    resolvedURL: firstItem.url,
                    fileName: resolvedFileName,
                    title: firstItem.title
                )
            }

            enqueueResolvedItems(
                Array(mediaItems.dropFirst()),
                sourceURL: sourceURL,
                template: template,
                argumentOverride: argumentOverride,
                after: itemID
            )
        } catch {
            let currentStatus = tasks.first(where: { $0.id == itemID })?.status
            guard currentStatus != .cancelled && currentStatus != .paused else {
                processQueue()
                return
            }

            update(itemID) {
                $0.status = .failed
                $0.message = error.localizedDescription
                $0.finishedAt = Date()
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }
            processQueue()
        }
    }

    private func enqueueResolvedItems(
        _ mediaItems: [ResolvedMediaItem],
        sourceURL: String,
        template: DownloadTemplate,
        argumentOverride: String?,
        after parentID: UUID
    ) {
        guard !mediaItems.isEmpty else { return }

        let insertionIndex = (tasks.firstIndex { $0.id == parentID } ?? -1) + 1
        let parentItem = tasks.first { $0.id == parentID }
        let newItems = mediaItems.map { mediaItem in
            var item = DownloadTaskItem(
                sourceURL: sourceURL,
                title: mediaItem.title ?? titleFromURL(mediaItem.url),
                mode: template.mode,
                templateName: template.name,
                templateArguments: template.arguments,
                resolverEndpoint: parentItem?.resolverEndpoint,
                resolverDelivery: parentItem?.resolverDelivery,
                resolverToken: parentItem?.resolverToken,
                argumentOverride: argumentOverride,
                status: .queued
            )
            item.resolvedURL = mediaItem.url
            item.resolvedAudioURL = mediaItem.audioURL
            item.fileName = mediaItem.filename
            return item
        }

        tasks.insert(contentsOf: newItems, at: min(max(insertionIndex, 0), tasks.count))
        save()
        processQueue()
    }

    private func startDownload(for itemID: UUID, resolvedURL: String, fileName: String?, title: String?) {
        guard let url = URL(string: resolvedURL) else {
            update(itemID) {
                $0.status = .failed
                $0.message = "Invalid URL"
                $0.finishedAt = Date()
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }
            processQueue()
            return
        }

        update(itemID) {
            $0.status = .downloading
            $0.resolvedURL = resolvedURL
            $0.fileName = fileName
            if let title, !title.isEmpty {
                $0.title = title
            }
            $0.message = nil
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
        }

        var request = URLRequest(url: url)
        CookieStore.apply(to: &request, referer: referer(for: url, sourceURL: tasks.first(where: { $0.id == itemID })?.sourceURL))
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.taskDescription(id: itemID, fileName: fileName)
        runningTasks[itemID] = task
        taskIDMap[task.taskIdentifier] = itemID
        saveTaskMap()
        task.resume()
    }

    private func startHLSDownload(for itemID: UUID, playlistURLString: String, fileName: String?, title: String?) {
        guard let playlistURL = URL(string: playlistURLString) else {
            failDownload(itemID, message: "Invalid HLS playlist URL")
            return
        }

        do {
            let destination = try Self.hlsDestinationURL(for: itemID, preferredFileName: fileName)
            update(itemID) {
                $0.status = .downloading
                $0.resolvedURL = playlistURLString
                $0.fileName = destination.lastPathComponent
                if let title, !title.isEmpty {
                    $0.title = title
                }
                $0.message = "Downloading HLS segments"
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }

            let startedAt = Date()
            let task = Task { [weak self] in
                guard let manager = self else { return }
                do {
                    try await HLSDownloader().download(playlistURL: playlistURL, destinationURL: destination) { progress in
                        Task { @MainActor in
                            manager.updateHLSProgress(itemID, progress: progress, startedAt: startedAt)
                        }
                    }

                    await MainActor.run {
                        manager.finishHLSDownload(itemID, destination: destination)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        manager.hlsTasks[itemID] = nil
                    }
                } catch {
                    await MainActor.run {
                        manager.failDownload(itemID, message: error.localizedDescription)
                    }
                }
            }

            hlsTasks[itemID] = task
        } catch {
            failDownload(itemID, message: error.localizedDescription)
        }
    }

    private func startDASHDownload(
        for itemID: UUID,
        videoURLString: String,
        audioURLString: String,
        pageURLString: String,
        fileName: String?,
        title: String?
    ) {
        guard let videoURL = URL(string: videoURLString),
              let audioURL = URL(string: audioURLString)
        else {
            failDownload(itemID, message: "Invalid DASH media URL")
            return
        }

        do {
            let destination = try Self.dashDestinationURL(for: itemID, preferredFileName: fileName)
            update(itemID) {
                $0.status = .downloading
                $0.resolvedURL = videoURLString
                $0.resolvedAudioURL = audioURLString
                $0.fileName = destination.lastPathComponent
                if let title, !title.isEmpty {
                    $0.title = title
                }
                $0.message = "Downloading separated video/audio"
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }

            let pageURL = URL(string: pageURLString)
            let task = Task { [weak self] in
                guard let manager = self else { return }
                do {
                    try await DASHMediaDownloader().downloadAndMerge(
                        videoURL: videoURL,
                        audioURL: audioURL,
                        pageURL: pageURL,
                        destinationURL: destination
                    ) { progress in
                        Task { @MainActor in
                            manager.updateDASHProgress(itemID, progress: progress)
                        }
                    }

                    await MainActor.run {
                        manager.finishDASHDownload(itemID, destination: destination)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        manager.dashTasks[itemID] = nil
                    }
                } catch {
                    await MainActor.run {
                        manager.failDownload(itemID, message: error.localizedDescription)
                    }
                }
            }

            dashTasks[itemID] = task
        } catch {
            failDownload(itemID, message: error.localizedDescription)
        }
    }

    private func startDASHManifestDownload(
        for itemID: UUID,
        manifestURLString: String,
        fileName: String?,
        title: String?
    ) {
        guard let manifestURL = URL(string: manifestURLString) else {
            failDownload(itemID, message: "Invalid DASH manifest URL")
            return
        }

        do {
            let destination = try Self.dashDestinationURL(for: itemID, preferredFileName: fileName)
            update(itemID) {
                $0.status = .downloading
                $0.resolvedURL = manifestURLString
                $0.fileName = destination.lastPathComponent
                if let title, !title.isEmpty {
                    $0.title = title
                }
                $0.message = "Parsing DASH manifest"
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }

            let pageURL = URL(string: tasks.first(where: { $0.id == itemID })?.sourceURL ?? manifestURLString)
            let task = Task { [weak self] in
                guard let manager = self else { return }
                do {
                    try await DASHMediaDownloader().downloadManifestAndMerge(
                        manifestURL: manifestURL,
                        pageURL: pageURL,
                        destinationURL: destination
                    ) { progress in
                        Task { @MainActor in
                            manager.updateDASHProgress(itemID, progress: progress)
                        }
                    }

                    await MainActor.run {
                        manager.finishDASHDownload(itemID, destination: destination)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        manager.dashTasks[itemID] = nil
                    }
                } catch {
                    await MainActor.run {
                        manager.failDownload(itemID, message: error.localizedDescription)
                    }
                }
            }

            dashTasks[itemID] = task
        } catch {
            failDownload(itemID, message: error.localizedDescription)
        }
    }

    private func startDownload(for itemID: UUID, resumeData: Data, fileName: String?) {
        update(itemID) {
            $0.status = .downloading
            $0.message = nil
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
        }

        let task = session.downloadTask(withResumeData: resumeData)
        task.taskDescription = Self.taskDescription(id: itemID, fileName: fileName)
        runningTasks[itemID] = task
        taskIDMap[task.taskIdentifier] = itemID
        saveTaskMap()
        task.resume()
    }

    private func removeRunningTask(id: UUID) {
        let task = runningTasks[id]
        task?.cancel()
        runningTasks[id] = nil
        hlsTasks[id]?.cancel()
        hlsTasks[id] = nil
        dashTasks[id]?.cancel()
        dashTasks[id] = nil
        if let task {
            taskIDMap[task.taskIdentifier] = nil
            saveTaskMap()
        }
    }

    private func updateHLSProgress(_ id: UUID, progress: HLSDownloadProgress, startedAt: Date) {
        let now = Date()
        update(id) {
            let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
            let speed = Double(progress.receivedBytes) / elapsed
            let segmentProgress = progress.totalSegments > 0
                ? Double(progress.completedSegments) / Double(progress.totalSegments)
                : 0

            $0.status = .downloading
            $0.progress = min(max(segmentProgress, 0), 1)
            $0.receivedBytes = progress.receivedBytes
            $0.totalBytes = 0
            $0.bytesPerSecond = speed.isFinite ? max(speed, 0) : 0
            if progress.completedSegments > 0, progress.completedSegments < progress.totalSegments {
                let remainingSegments = progress.totalSegments - progress.completedSegments
                let secondsPerSegment = elapsed / Double(progress.completedSegments)
                $0.estimatedRemainingSeconds = secondsPerSegment * Double(remainingSegments)
            } else {
                $0.estimatedRemainingSeconds = nil
            }
            $0.lastProgressAt = now
            $0.message = "Downloaded \(progress.completedSegments)/\(progress.totalSegments) HLS segments"
        }
    }

    private func finishHLSDownload(_ id: UUID, destination: URL) {
        update(id) {
            $0.status = .finished
            $0.progress = 1
            $0.localPath = destination.path
            $0.fileName = destination.lastPathComponent
            $0.finishedAt = Date()
            $0.message = "Saved to Documents"
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
        }
        if AppSettings.notificationsEnabledPreference {
            NotificationCenterService.notifyDownloadFinished(
                title: tasks.first(where: { $0.id == id })?.title ?? destination.lastPathComponent,
                fileName: destination.lastPathComponent
            )
        }
        hlsTasks[id] = nil
        processQueue()
    }

    private func updateDASHProgress(_ id: UUID, progress: DASHMediaDownloadProgress) {
        update(id) {
            $0.status = .downloading
            $0.progress = min(max(progress.progress, 0), 1)
            $0.message = Self.dashProgressMessage(for: progress.stage)
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = Date()
        }
    }

    private func finishDASHDownload(_ id: UUID, destination: URL) {
        update(id) {
            $0.status = .finished
            $0.progress = 1
            $0.localPath = destination.path
            $0.fileName = destination.lastPathComponent
            $0.finishedAt = Date()
            $0.message = "Merged and saved to Documents"
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
        }
        if AppSettings.notificationsEnabledPreference {
            NotificationCenterService.notifyDownloadFinished(
                title: tasks.first(where: { $0.id == id })?.title ?? destination.lastPathComponent,
                fileName: destination.lastPathComponent
            )
        }
        dashTasks[id] = nil
        processQueue()
    }

    private func failDownload(_ id: UUID, message: String) {
        update(id) {
            $0.status = .failed
            $0.message = message
            $0.finishedAt = Date()
            $0.bytesPerSecond = 0
            $0.estimatedRemainingSeconds = nil
            $0.lastProgressAt = nil
            $0.resumeData = nil
        }
        if AppSettings.notificationsEnabledPreference {
            NotificationCenterService.notifyDownloadFailed(
                title: tasks.first(where: { $0.id == id })?.title ?? "Download",
                message: message
            )
        }
        hlsTasks[id] = nil
        dashTasks[id] = nil
        processQueue()
    }

    private func update(_ id: UUID, mutate: (inout DownloadTaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DownloadTaskItem].self, from: data)
        else { return }

        tasks = decoded.map { item in
            var copy = item
            if copy.status == .downloading {
                copy.status = .downloading
                copy.message = "Waiting for system resume"
                copy.bytesPerSecond = 0
                copy.estimatedRemainingSeconds = nil
                copy.lastProgressAt = nil
                copy.resumeData = nil
            } else if copy.status == .resolving {
                copy.status = .queued
                copy.message = "Queued after restart"
                copy.bytesPerSecond = 0
                copy.estimatedRemainingSeconds = nil
                copy.lastProgressAt = nil
            }
            return copy
        }
    }

    private func restoreRunningTasks() {
        session.getAllTasks { [weak self] urlSessionTasks in
            guard let self else { return }

            Task { @MainActor in
                for urlSessionTask in urlSessionTasks {
                    guard let downloadTask = urlSessionTask as? URLSessionDownloadTask else {
                        continue
                    }

                    guard let id = Self.runningTaskDescription(from: downloadTask.taskDescription)?.id
                        ?? self.taskIDMap[downloadTask.taskIdentifier]
                    else {
                        continue
                    }

                    self.runningTasks[id] = downloadTask
                    self.taskIDMap[downloadTask.taskIdentifier] = id
                    self.update(id) {
                        $0.status = .downloading
                        $0.message = "Resumed by iOS"
                        $0.bytesPerSecond = 0
                        $0.estimatedRemainingSeconds = nil
                        $0.lastProgressAt = nil
                        $0.resumeData = nil
                    }
                }
                self.saveTaskMap()

                let runningIDs = Set(self.runningTasks.keys)
                for item in self.tasks where item.status == .downloading && !runningIDs.contains(item.id) {
                    self.update(item.id) {
                        $0.status = .failed
                        $0.message = "Background download was not restored"
                        $0.finishedAt = Date()
                        $0.bytesPerSecond = 0
                        $0.estimatedRemainingSeconds = nil
                        $0.lastProgressAt = nil
                    }
                }
                self.processQueue()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadTaskMap() {
        guard let data = UserDefaults.standard.data(forKey: taskMapKey),
              let decoded = try? JSONDecoder().decode([Int: UUID].self, from: data)
        else { return }

        taskIDMap = decoded
    }

    private func saveTaskMap() {
        if let data = try? JSONEncoder().encode(taskIDMap) {
            UserDefaults.standard.set(data, forKey: taskMapKey)
        }
    }

    private func titleFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "New download" }
        let lastPath = url.lastPathComponent
        if lastPath.isEmpty {
            return url.host ?? "New download"
        }
        return lastPath
    }

    private nonisolated static func cleanArgumentOverride(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private nonisolated static func cleanPreferredFileName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return sanitizedFileName(trimmed)
    }

    private nonisolated static func titleFromFileName(_ fileName: String) -> String {
        URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    nonisolated static func isDirectDownloadURL(_ urlString: String) -> Bool {
        BackendResolver.isDirectDownloadURL(urlString)
    }

    nonisolated static func isHLSPlaylistURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.pathExtension.lowercased() == "m3u8"
    }

    nonisolated static func isDASHManifestURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.pathExtension.lowercased() == "mpd"
    }

    private func referer(for mediaURL: URL, sourceURL: String?) -> String? {
        if mediaURL.host?.contains("bilivideo") == true {
            return "https://www.bilibili.com/"
        }
        guard let sourceURL,
              let source = URL(string: sourceURL),
              let scheme = source.scheme,
              let host = source.host
        else {
            return nil
        }
        return "\(scheme)://\(host)/"
    }

    private nonisolated static func dashProgressMessage(for stage: DASHMediaDownloadProgress.Stage) -> String {
        switch stage {
        case .downloadingVideo:
            "Downloading DASH video stream"
        case .downloadingAudio:
            "Downloading DASH audio stream"
        case .merging:
            "Merging video and audio"
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let description = Self.runningTaskDescription(from: downloadTask.taskDescription) else { return }
        let id = description.id
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        Task { @MainActor in
            let now = Date()
            update(id) {
                let previousReceivedBytes = $0.receivedBytes
                let elapsed = $0.lastProgressAt.map { now.timeIntervalSince($0) } ?? 0
                let deltaBytes = totalBytesWritten - previousReceivedBytes
                let speed = elapsed > 0 && deltaBytes >= 0 ? Double(deltaBytes) / elapsed : $0.bytesPerSecond

                $0.status = .downloading
                $0.progress = min(max(progress, 0), 1)
                $0.receivedBytes = totalBytesWritten
                $0.totalBytes = totalBytesExpectedToWrite
                $0.bytesPerSecond = speed.isFinite ? max(speed, 0) : 0
                if totalBytesExpectedToWrite > 0, $0.bytesPerSecond > 0 {
                    let remainingBytes = max(totalBytesExpectedToWrite - totalBytesWritten, 0)
                    $0.estimatedRemainingSeconds = Double(remainingBytes) / $0.bytesPerSecond
                } else {
                    $0.estimatedRemainingSeconds = nil
                }
                $0.lastProgressAt = now
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let description = Self.runningTaskDescription(from: downloadTask.taskDescription) else { return }
        let id = description.id

        do {
            let destination = try Self.destinationURL(
                for: id,
                preferredFileName: description.fileName,
                response: downloadTask.response
            )
            try FileManager.default.moveItem(at: location, to: destination)

            Task { @MainActor in
                update(id) {
                    $0.status = .finished
                    $0.progress = 1
                    $0.localPath = destination.path
                    $0.fileName = destination.lastPathComponent
                    $0.finishedAt = Date()
                    $0.message = "Saved to Documents"
                    $0.bytesPerSecond = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.lastProgressAt = nil
                    $0.resumeData = nil
                }
                if AppSettings.notificationsEnabledPreference {
                    NotificationCenterService.notifyDownloadFinished(
                        title: tasks.first(where: { $0.id == id })?.title ?? destination.lastPathComponent,
                        fileName: destination.lastPathComponent
                    )
                }
                runningTasks[id] = nil
                taskIDMap[downloadTask.taskIdentifier] = nil
                saveTaskMap()
                processQueue()
            }
        } catch {
            Task { @MainActor in
                update(id) {
                    $0.status = .failed
                    $0.message = error.localizedDescription
                    $0.finishedAt = Date()
                    $0.bytesPerSecond = 0
                    $0.estimatedRemainingSeconds = nil
                    $0.lastProgressAt = nil
                    $0.resumeData = nil
                }
                if AppSettings.notificationsEnabledPreference {
                    NotificationCenterService.notifyDownloadFailed(
                        title: tasks.first(where: { $0.id == id })?.title ?? "Download",
                        message: error.localizedDescription
                    )
                }
                runningTasks[id] = nil
                taskIDMap[downloadTask.taskIdentifier] = nil
                saveTaskMap()
                processQueue()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let description = Self.runningTaskDescription(from: task.taskDescription)
        else { return }
        let id = description.id

        Task { @MainActor in
            let currentStatus = tasks.first(where: { $0.id == id })?.status
            if currentStatus == .cancelled || currentStatus == .paused {
                runningTasks[id] = nil
                taskIDMap[task.taskIdentifier] = nil
                saveTaskMap()
                processQueue()
                return
            }

            update(id) {
                $0.status = .failed
                $0.message = error.localizedDescription
                $0.finishedAt = Date()
                $0.bytesPerSecond = 0
                $0.estimatedRemainingSeconds = nil
                $0.lastProgressAt = nil
                $0.resumeData = nil
            }
            if AppSettings.notificationsEnabledPreference {
                NotificationCenterService.notifyDownloadFailed(
                    title: tasks.first(where: { $0.id == id })?.title ?? "Download",
                    message: error.localizedDescription
                )
            }
            runningTasks[id] = nil
            taskIDMap[task.taskIdentifier] = nil
            saveTaskMap()
            processQueue()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            guard let identifier = session.configuration.identifier,
                  let completionHandler = Self.backgroundCompletionHandlers.removeValue(forKey: identifier)
            else {
                return
            }

            completionHandler()
        }
    }

    private nonisolated static func destinationURL(
        for id: UUID,
        preferredFileName: String?,
        response: URLResponse?
    ) throws -> URL {
        let folder = Self.downloadsFolderURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let responseName = response?.suggestedFilename
        let preferredName = Self.fileName(
            preferredFileName: preferredFileName,
            responseFileName: responseName,
            fallback: "download-\(id.uuidString.prefix(8))"
        )
        let candidate = folder.appendingPathComponent(Self.sanitizedFileName(preferredName))
        return Self.availableFileURL(for: candidate)
    }

    private nonisolated static func hlsDestinationURL(
        for id: UUID,
        preferredFileName: String?
    ) throws -> URL {
        let folder = Self.downloadsFolderURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let preferredName = Self.fileName(
            preferredFileName: preferredFileName,
            responseFileName: "download-\(id.uuidString.prefix(8)).ts",
            fallback: "download-\(id.uuidString.prefix(8)).ts"
        )
        let normalizedName = URL(fileURLWithPath: preferredName).pathExtension.lowercased() == "m3u8"
            ? "\(URL(fileURLWithPath: preferredName).deletingPathExtension().lastPathComponent).ts"
            : preferredName
        let candidate = folder.appendingPathComponent(Self.sanitizedFileName(normalizedName))
        return Self.availableFileURL(for: candidate)
    }

    private nonisolated static func dashDestinationURL(
        for id: UUID,
        preferredFileName: String?
    ) throws -> URL {
        let folder = Self.downloadsFolderURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let preferredName = Self.fileName(
            preferredFileName: preferredFileName,
            responseFileName: "download-\(id.uuidString.prefix(8)).mp4",
            fallback: "download-\(id.uuidString.prefix(8)).mp4"
        )
        let url = URL(fileURLWithPath: preferredName)
        let normalizedName = url.pathExtension.isEmpty
            ? "\(url.lastPathComponent).mp4"
            : "\(url.deletingPathExtension().lastPathComponent).mp4"
        let candidate = folder.appendingPathComponent(Self.sanitizedFileName(normalizedName))
        return Self.availableFileURL(for: candidate)
    }

    private nonisolated static func fileName(
        preferredFileName: String?,
        responseFileName: String?,
        fallback: String
    ) -> String {
        guard let preferredFileName, !preferredFileName.isEmpty else {
            return responseFileName ?? fallback
        }

        let preferredURL = URL(fileURLWithPath: preferredFileName)
        guard preferredURL.pathExtension.isEmpty,
              let responseExtension = responseFileName.map({ URL(fileURLWithPath: $0).pathExtension }),
              !responseExtension.isEmpty
        else {
            return preferredFileName
        }

        return "\(preferredFileName).\(responseExtension)"
    }

    private nonisolated static func taskDescription(id: UUID, fileName: String?) -> String {
        let description = RunningTaskDescription(id: id, fileName: fileName)
        guard let data = try? JSONEncoder().encode(description),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return id.uuidString
        }

        return encoded
    }

    private nonisolated static func runningTaskDescription(from value: String?) -> RunningTaskDescription? {
        guard let value else { return nil }

        if let id = UUID(uuidString: value) {
            return RunningTaskDescription(id: id, fileName: nil)
        }

        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RunningTaskDescription.self, from: data)
    }

    private nonisolated static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }

    private nonisolated static func availableFileURL(for candidate: URL) -> URL {
        guard FileManager.default.fileExists(atPath: candidate.path) else {
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
            if !FileManager.default.fileExists(atPath: nextURL.path) {
                return nextURL
            }
        }

        let fallbackName = fileExtension.isEmpty
            ? "\(baseName) \(UUID().uuidString)"
            : "\(baseName) \(UUID().uuidString).\(fileExtension)"
        return directory.appendingPathComponent(fallbackName)
    }

    private nonisolated static func downloadsFolderURL() -> URL {
        FileLibraryStore.downloadsFolderURL()
    }
}
