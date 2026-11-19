import AppKit
import Observation
import Sparkle

@MainActor
protocol AppUpdaterBackend: AnyObject {
    var canCheckForUpdates: Bool { get }
    func start() throws
    func checkInformation()
    func checkUpdates()
}

struct AppUpdatePresentation: Equatable {
    enum Phase { case checking, available, downloading, extracting, ready, installing, failed, current }
    var version: String?
    var phase: Phase
    var progress: Double?
    var informationURL: URL?
    var informationOnly = false
    var publishedAt: Date?
    var isCheckFailure = false
    var downloadedBytes: UInt64 = 0
    var totalDownloadBytes: UInt64?
    var failure: AppUpdateFailure?

    var errorMessage: String? { failure?.message }

    var usesCheckDialog: Bool {
        phase == .checking || phase == .current || (phase == .failed && isCheckFailure)
    }
}

/// Only known error codes become user-facing text. SDK descriptions and their
/// underlying metadata may contain URLs, local paths or other private details.
enum AppUpdateFailure: Equatable, Sendable {
    case networkUnavailable, invalidUpdate, insufficientSpace

    static func classify(_ error: any Error) -> Self? {
        var current = error as NSError
        // Sparkle wraps download and file errors. Bound traversal even if an
        // unexpected error supplies a cyclic or unusually deep cause chain.
        for _ in 0..<8 {
            if current.domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: current.code) {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                     .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                    return .networkUnavailable
                default: break
                }
            }
            if current.domain == NSCocoaErrorDomain,
               current.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return .insufficientSpace
            }
            if current.domain == SUSparkleErrorDomain {
                switch current.code {
                case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue),
                     Int(SUError.unarchivingError.rawValue), Int(SUError.notValidUpdateError.rawValue):
                    return .invalidUpdate
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
            current = underlying
        }
        return nil
    }

    var message: String {
        switch self {
        case .networkUnavailable:
            L10n.string("Unable to complete the update request. Check your network connection and try again. If you use a proxy or VPN, confirm that it can reach the update server.")
        case .invalidUpdate:
            L10n.string("TSX could not verify the downloaded update. Please try downloading the update again.")
        case .insufficientSpace:
            L10n.string("There is not enough free space to prepare the update. Free up some disk space and try again.")
        }
    }
}

enum AppReleaseNotesMode: Hashable {
    case recent
    case installed(version: String)
}

enum AppUpdateLocation { case settings, mainWindow }

/// Sparkle owns feed/archive verification, installation, authorization and relaunch.
/// The app chooses when to probe and keeps update progress in its initiating window.
@MainActor
@Observable
final class AppUpdateController {
    private(set) var canCheckForUpdates = false
    private(set) var mode: UpdateMode = .notify
    var automaticallyChecksForUpdates: Bool { started && mode != .manual }
    var automaticallyDownloadsUpdates: Bool { started && mode == .install }
    var needsUpdateChoice: Bool { isAvailable && !schedule.confirmed }
    private(set) var isChoosingUpdateMode = false
    private(set) var preparedForQuit = false
    private var retryTermination: (() -> Void)?
    var canRetryTermination: Bool { retryTermination != nil }
    private let schedule: UpdateSchedule
    private var probeActive = false
    private var feedVerified = false
    private var resolvedFeed = false
    private var candidateBuild: String?
    private var automaticBuild: String?
    private var canDownloadCandidate = false
    private var candidateInformationURL: URL?
    private var withdrawing = false
    private var resumedOffer = false
    private var skippedPreferences: [String: Any]?
    private var terminationReplies: [() -> Void] = []
    private static let skippedKeys = ["SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"]
    private(set) var started = false
    private(set) var availableVersion: String?
    private var availablePublishedAt: Date?
    private(set) var hasChecked = false
    private(set) var isChecking = false
    private(set) var lastCheckFailed = false
    private(set) var updatePresentation: AppUpdatePresentation?
    private(set) var updateLocation: AppUpdateLocation = .mainWindow
    private var mainUpdatePresentationApproved = false
    private(set) var pendingReleaseNotesVersion: String?
    private(set) var releaseNotesPresentation: AppReleaseNotesMode?
    private(set) var mainReleaseNotesPresentation: AppReleaseNotesMode?
    let currentVersion: String
    let isAvailable: Bool
    let releases: AppReleaseNotesStore
    var automaticUpdatesEnabled: Bool { automaticallyDownloadsUpdates }
    var isPresentingModal: Bool { updatePresentation != nil || releaseNotesPresentation != nil }
    var showsMainUpdate: Bool { updateLocation == .mainWindow && mainUpdatePresentationApproved && updatePresentation != nil }
    var showsSettingsUpdate: Bool { updateLocation == .settings && updatePresentation != nil }
    var isPresentingMainModal: Bool { showsMainUpdate || mainReleaseNotesPresentation != nil }
    var isPresentingSettingsModal: Bool { isChoosingUpdateMode || showsSettingsUpdate || releaseNotesPresentation != nil }
    @ObservationIgnored var onPresentUpdate: (() -> Void)?
    @ObservationIgnored var onPresentReleaseNotes: (() -> Void)?
    @ObservationIgnored private var backend: (any AppUpdaterBackend)?
    @ObservationIgnored private var nativeBackend: SparkleAppUpdater?
    @ObservationIgnored private lazy var menuTarget = AppUpdateMenuTarget(owner: self)
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recordsInstalledVersions: Bool
    @ObservationIgnored private let hadLegacyLaunch: Bool
    @ObservationIgnored private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var automaticSession = false
    private enum CheckOrigin { case launch, manual, releaseNotes }
    private enum SessionPhase { case checking, offered, installing, cancelled }
    @ObservationIgnored private var checkOrigin: CheckOrigin = .launch
    @ObservationIgnored private var sessionPhase: SessionPhase = .checking
    @ObservationIgnored private var installRequested = false
    @ObservationIgnored private var directlyRequestedVersion: String?
    @ObservationIgnored private var offeredDownloadBytes: UInt64 = 0
    @ObservationIgnored private var expectedDownloadBytes: UInt64 = 0
    @ObservationIgnored private var receivedDownloadBytes: UInt64 = 0

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         isTesting: Bool = NSClassFromString("XCTestCase") != nil,
         isReleaseBuild: Bool = AppUpdateController.isReleaseBuild,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
         defaults: UserDefaults = .standard,
         recordsInstalledVersions: Bool = AppUpdateController.isReleaseBuild,
         now: @escaping () -> Date = Date.init,
         backend: (any AppUpdaterBackend)? = nil,
         releases: AppReleaseNotesStore? = nil) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.recordsInstalledVersions = recordsInstalledVersions
        // Capture before starting Sparkle: 1.0.0 only persisted this launch marker.
        hadLegacyLaunch = defaults.bool(forKey: "SUHasLaunchedBefore")
        self.backend = backend
        // A release update must never replace Xcode's development product.
        let available = bundleIdentifier == "com.lumax.tsx" && !isTesting && isReleaseBuild
        self.releases = releases ?? AppReleaseNotesStore(allowsNetworkLoading: available)
        schedule = UpdateSchedule(defaults: defaults, legacyMode: defaults.bool(forKey: "SUAutomaticallyUpdate") ? .install : .notify,
                                  monitorsNetwork: backend == nil, now: now)
        mode = schedule.mode
        if available, let version = defaults.string(forKey: "TSXAvailableVersion"),
           SUStandardVersionComparator().compareVersion(version, toVersion: currentVersion) == .orderedDescending {
            availableVersion = version
        }
        isAvailable = available
    }

    func start() {
        guard isAvailable, !started else { return }
        prepareInstalledReleaseNotes()
        guard schedule.confirmed, startBackend() else { return }
        schedule.observe { [weak self] in self?.checkIfDue(reconnected: $0) }
        checkIfDue()
    }

    func checkIfDue(reconnected: Bool = false) {
        guard started, !probeActive, !isChecking, backend?.canCheckForUpdates == true, updatePresentation == nil,
              !automaticSession, !withdrawing, schedule.due(reconnected: reconnected) else { return }
        checkOrigin = .launch
        beginProbe()
    }

    private func beginProbe() {
        feedVerified = false
        resolvedFeed = false
        probeActive = true
        sessionPhase = .checking
        releases.beginLoading(force: true)
        isChecking = true
        backend?.checkInformation()
    }

    private func startBackend() -> Bool {
        guard isAvailable else { return false }
        if started { return true }
        if backend == nil {
            let native = SparkleAppUpdater(owner: self)
            nativeBackend = native
            backend = native
        }
        guard let backend else { return false }
        do { try backend.start() }
        catch { checkFailed(); return false }
        started = true
        refreshUpdaterState()
        return true
    }

    func refreshUpdaterState() {
        guard isAvailable, let backend else { return }
        canCheckForUpdates = backend.canCheckForUpdates
        if probeActive || automaticSession { canCheckForUpdates = true }
    }

    func checkForUpdates(in location: AppUpdateLocation = .mainWindow) {
        if probeActive {
            updateLocation = location
            checkOrigin = .manual
            present(.init(phase: .checking))
            return
        }
        if automaticSession { revealAutomatic(in: location); return }
        if updatePresentation != nil { focusUpdate(); return }
        beginUpdateCheck(in: location, installing: nil)
    }

    private func beginUpdateCheck(in location: AppUpdateLocation, installing version: String?) {
        guard started, canCheckForUpdates, !isChecking, !withdrawing else { return }
        updateLocation = location
        directlyRequestedVersion = version
        offeredDownloadBytes = 0
        installRequested = false
        automaticSession = false
        feedVerified = false; resolvedFeed = false
        checkOrigin = .manual; sessionPhase = .checking
        releases.beginLoading(force: true)
        lastCheckFailed = false
        isChecking = true
        present(.init(phase: .checking))
        backend?.checkUpdates()
    }

    func performUpdateAction(in location: AppUpdateLocation = .mainWindow) {
        if location == .settings, canRetryTermination { restartNow(); return }
        if probeActive { checkForUpdates(in: location); return }
        if automaticSession {
            if preparedForQuit && location == .settings {
                updateLocation = location
                restartNow()
            } else { revealAutomatic(in: location) }
            return
        }
        if let presentation = updatePresentation {
            if presentation.phase == .checking && updateLocation == location { return }
            if location == .settings, [.available, .ready].contains(presentation.phase) {
                updateLocation = .settings
                mainUpdatePresentationApproved = false
                automaticSession = false
                installPendingUpdate()
            }
            onPresentUpdate?()
            return
        }
        guard started, canCheckForUpdates, !isChecking else { return }
        if let version = availableVersion {
            beginUpdateCheck(in: location, installing: location == .settings ? version : nil)
        }
        else {
            beginUpdateCheck(in: location, installing: nil)
        }
    }

    func retryUpdate() {
        guard let presentation = updatePresentation, presentation.phase == .failed else { return }
        let location = updateLocation
        dismissUpdate()
        if location == .settings && !presentation.isCheckFailure { performUpdateAction(in: .settings) }
        else { checkForUpdates(in: location) }
    }

    func presentUpdateChoiceIfNeeded() {
        isChoosingUpdateMode = needsUpdateChoice
    }

    func setMode(_ value: UpdateMode) {
        guard isAvailable else { return }
        let wasInstall = mode == .install
        isChoosingUpdateMode = false
        schedule.select(value)
        mode = value
        if wasInstall && value != .install && automaticSession { withdrawInstallation() }
        if started { checkIfDue() } else { start() }
    }

    func setAutomaticUpdates(_ enabled: Bool) { setMode(enabled ? .install : .notify) }
    func setAutomaticChecks(_ enabled: Bool) { setMode(enabled ? .notify : .manual) }
    func setAutomaticDownloads(_ enabled: Bool) { setAutomaticUpdates(enabled) }

    private func withdrawInstallation() {
        withdrawing = true
        preparedForQuit = false
        if let reply = updateReply {
            updateReply = nil
            if resumedOffer {
                skippedPreferences = Dictionary(uniqueKeysWithValues: Self.skippedKeys.compactMap { key in
                    defaults.object(forKey: key).map { (key, $0) }
                })
            }
            reply(sessionPhase == .installing ? .skip : .dismiss)
        } else if let cancel = cancellation {
            cancellation = nil
            cancel()
        }
    }

    var mustCancelBeforeQuit: Bool { withdrawing || (resumedOffer && !automaticSession && !installRequested) }

    func prepareForOrdinaryTermination(_ completion: @escaping () -> Void) {
        if mustCancelBeforeQuit {
            terminationReplies.append(completion)
            if !withdrawing { withdrawInstallation() }
            return
        }
        completion()
    }

    private func revealAutomatic(in location: AppUpdateLocation) {
        updateLocation = location
        if updatePresentation == nil { present(.init(version: availableVersion, phase: preparedForQuit ? .ready : .checking)) }
        else { onPresentUpdate?() }
    }

    func restartNow() {
        if let retryTermination { self.retryTermination = nil; retryTermination(); return }
        guard preparedForQuit, mode == .install, !withdrawing, let reply = updateReply else { return }
        preparedForQuit = false
        automaticSession = false
        updateReply = nil
        installRequested = true
        reply(.install)
    }

    func recordFeedVerification(_ verified: Bool) { feedVerified = verified }

    private func recordResolution() {
        if isAvailable, feedVerified, !resolvedFeed, !probeActive { schedule.succeeded() }
        resolvedFeed = true
    }

    var rejectsUnsignedResult: Bool { !feedVerified }

    func foundUpdate(_ version: String, publishedAt: Date? = nil, build: String? = nil, downloadable: Bool = true, informationURL: URL? = nil) {
        candidateBuild = build ?? version
        canDownloadCandidate = downloadable
        candidateInformationURL = informationURL?.scheme == "https" ? informationURL : nil
        recordResolution()
        if isAvailable, feedVerified { defaults.set(version, forKey: "TSXAvailableVersion") }
        availablePublishedAt = publishedAt ?? (availableVersion == version ? availablePublishedAt : nil)
        availableVersion = version; hasChecked = true; lastCheckFailed = false
    }
    func foundNoUpdate() {
        recordResolution()
        if isAvailable, feedVerified { defaults.removeObject(forKey: "TSXAvailableVersion") }
        directlyRequestedVersion = nil; installRequested = false
        availablePublishedAt = nil
        availableVersion = nil; hasChecked = true; lastCheckFailed = false; isChecking = false
    }
    func checkFailed() {
        directlyRequestedVersion = nil; installRequested = false
        lastCheckFailed = true; isChecking = false
        releases.loadingFailed()
    }
    private var cycleError: NSError?
    func checkAborted(_ error: any Error) {
        cycleError = error as NSError
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
            if feedVerified { foundNoUpdate() } else { checkFailed() }
        }
        else if error.domain != SUSparkleErrorDomain || error.code != Int(SUError.installationCanceledError.rawValue) { checkFailed() }
        else {
            directlyRequestedVersion = nil; installRequested = false; isChecking = false
            sessionPhase = .cancelled; releases.loadingFailed()
        }
    }
    func finishedCheck(error: Error? = nil) {
        let failure = (error as NSError?) ?? cycleError
        cycleError = nil
        let current = failure?.domain == SUSparkleErrorDomain && failure?.code == Int(SUError.noUpdateError.rawValue)
        let cancelled = sessionPhase == .cancelled || (failure?.domain == SUSparkleErrorDomain && failure?.code == Int(SUError.installationCanceledError.rawValue))
        let success = feedVerified && resolvedFeed && (failure == nil || current)
        let probe = probeActive
        if probe, success, !cancelled { schedule.succeeded() }
        let visible = probe && checkOrigin == .manual && !cancelled
        let autoDownload = probe && success && mode == .install && availableVersion != nil && canDownloadCandidate
        if !success && !cancelled && (probe || sessionPhase == .checking), failure != nil || probe {
            schedule.failed(network: failure.flatMap(AppUpdateFailure.classify) == .networkUnavailable)
        }
        if probe, !success, !cancelled { checkFailed() }
        probeActive = false
        automaticSession = false
        withdrawing = false
        preparedForQuit = false
        retryTermination = nil
        resumedOffer = false
        if let snapshot = skippedPreferences {
            for key in Self.skippedKeys { defaults.set(snapshot[key], forKey: key) }
            skippedPreferences = nil
        }
        let replies = terminationReplies
        terminationReplies.removeAll()
        isChecking = false; releases.loadingFailed(); refreshUpdaterState()
        if visible {
            if success, let version = availableVersion {
                present(.init(version: version, phase: .available, informationURL: candidateInformationURL,
                              informationOnly: !canDownloadCandidate, publishedAt: availablePublishedAt))
            } else if success { present(.init(phase: .current)) }
            else { present(.init(phase: .failed, isCheckFailure: true, failure: failure.flatMap(AppUpdateFailure.classify))) }
        }
        replies.forEach { $0() }
        if autoDownload, replies.isEmpty, let build = candidateBuild {
            Task { @MainActor [weak self] in
                guard let self, mode == .install, !probeActive, !isChecking, backend?.canCheckForUpdates == true else { return }
                automaticSession = true
                automaticBuild = build
                installRequested = false
                sessionPhase = .checking
                isChecking = true
                feedVerified = false; resolvedFeed = false
                backend?.checkUpdates()
            }
        }
    }

    func installPendingUpdate() {
        if preparedForQuit { restartNow(); return }
        guard updatePresentation?.informationOnly == false else { return }
        guard let reply = updateReply else {
            if let presentation = updatePresentation, presentation.phase == .available {
                updatePresentation = nil
                beginUpdateCheck(in: updateLocation, installing: presentation.version)
            }
            return
        }
        directlyRequestedVersion = nil
        updateReply = nil
        installRequested = true
        reply(.install)
    }

    /// Called only after the window coordinator has passed the settings draft
    /// guard. A pending update alone must not mount a modal or trigger a restart.
    func presentUpdateInMainWindow() {
        guard updateLocation == .mainWindow, updatePresentation != nil else { return }
        mainUpdatePresentationApproved = true
    }

    func dismissUpdate() {
        guard let presentation = updatePresentation else { return }
        if automaticSession {
            updatePresentation = nil
            return
        }
        if [.extracting, .installing].contains(presentation.phase) { return }
        directlyRequestedVersion = nil
        let cancel = cancellation
        cancellation = nil
        let reply = updateReply
        updateReply = nil
        sessionPhase = .cancelled
        updatePresentation = nil
        cancel?()
        reply?(presentation.phase == .ready ? .skip : .dismiss)
        installRequested = false
    }

    func showUpdateCheck(cancellation: @escaping () -> Void) {
        if sessionPhase == .cancelled { cancellation(); return }
        self.cancellation = cancellation
        if withdrawing { withdrawInstallation(); return }
        sessionPhase = .checking
        if !automaticSession && !probeActive {
            checkOrigin = .manual
            present(.init(phase: .checking))
        }
    }

    func offerUpdate(version: String, informationOnly: Bool, informationURL: URL?, publishedAt: Date? = nil,
                     downloadSize: UInt64 = 0,
                     build: String? = nil, resumed: Bool = false, userInitiated: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offeredDownloadBytes = downloadSize
        foundUpdate(version, publishedAt: publishedAt, build: build, downloadable: !informationOnly)
        sessionPhase = .offered
        isChecking = false
        cancellation = nil
        updateReply = reply
        if automaticSession {
            updateReply = nil
            if resumed {
                if automaticBuild != candidateBuild { withdrawing = true }
                resumedOffer = true
                readyToInstall(reply: reply)
            } else if mode == .install, !withdrawing, automaticBuild == candidateBuild, !informationOnly {
                reply(.install)
            } else { reply(.dismiss) }
            return
        }
        if resumed { resumedOffer = true; readyToInstall(reply: reply); return }
        let requestedVersion = directlyRequestedVersion
        directlyRequestedVersion = nil
        let safeURL = informationURL?.scheme == "https" ? informationURL : nil
        present(.init(version: version, phase: .available, informationURL: safeURL,
                      informationOnly: informationOnly, publishedAt: availablePublishedAt))
        // The version-labelled About action already expressed install intent.
        // A different candidate or information-only release still needs review.
        if requestedVersion == version, !informationOnly { installPendingUpdate() }
    }

    func downloadStarted(cancellation: @escaping () -> Void) {
        sessionPhase = .installing
        self.cancellation = cancellation
        receivedDownloadBytes = 0; expectedDownloadBytes = offeredDownloadBytes
        updateDownloadProgress()
        if withdrawing { withdrawInstallation() }
    }
    func downloadExpected(_ bytes: UInt64) {
        // An unknown HTTP length must not erase the size from the verified feed.
        if bytes > 0 { expectedDownloadBytes = bytes }
        updateDownloadProgress()
    }
    func downloadReceived(_ bytes: UInt64) {
        receivedDownloadBytes = receivedDownloadBytes.addingReportingOverflow(bytes).overflow ? UInt64.max : receivedDownloadBytes + bytes
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        setPhase(.downloading, progress: expectedDownloadBytes > 0 ? min(1, Double(receivedDownloadBytes) / Double(expectedDownloadBytes)) : nil)
    }
    func extractionStarted() { cancellation = nil; setPhase(.extracting, progress: nil) }
    func extractionProgress(_ progress: Double) { setPhase(.extracting, progress: progress.isFinite ? min(1, max(0, progress)) : nil) }
    func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        sessionPhase = .installing
        if automaticSession {
            updateReply = reply
            if withdrawing || mode != .install { withdrawInstallation() }
            else {
                preparedForQuit = true
                if updatePresentation != nil { setPhase(.ready, progress: nil) }
            }
            return
        }
        setPhase(.ready, progress: nil)
        if installRequested { reply(.install) }
        else { updateReply = reply }
    }
    func installing(retry: (() -> Void)? = nil) {
        retryTermination = retry
        cancellation = nil
        updateReply = nil
        setPhase(.installing, progress: nil)
    }
    func updateErrored(_ error: (any Error)? = nil) {
        let isCheckFailure = sessionPhase == .checking
        let silent = (automaticSession && updatePresentation == nil) || sessionPhase == .cancelled || (isCheckFailure && checkOrigin != .manual)
        checkFailed(); cancellation = nil; updateReply = nil
        guard !silent else { return }
        present(.init(version: availableVersion, phase: .failed, isCheckFailure: isCheckFailure,
                      failure: error.flatMap { AppUpdateFailure.classify($0) }))
    }
    func updateNotFound() {
        foundNoUpdate(); cancellation = nil; updateReply = nil
        if !automaticSession && checkOrigin == .manual { present(.init(phase: .current)) }
    }
    func installationDismissed() {
        retryTermination = nil
        directlyRequestedVersion = nil
        cancellation = nil; updateReply = nil; installRequested = false
        if let phase = updatePresentation?.phase, ![.failed, .current].contains(phase) { updatePresentation = nil }
    }
    func focusUpdate() { if updatePresentation != nil { onPresentUpdate?() } }
    private func setPhase(_ phase: AppUpdatePresentation.Phase, progress: Double?) {
        if [.downloading, .extracting, .ready, .installing].contains(phase) { sessionPhase = .installing }
        if automaticSession && updatePresentation == nil { return }
        var presentation = updatePresentation ?? .init(version: availableVersion, phase: phase, publishedAt: availablePublishedAt)
        presentation.phase = phase; presentation.progress = progress
        presentation.downloadedBytes = phase == .downloading ? receivedDownloadBytes : 0
        presentation.totalDownloadBytes = phase == .downloading && expectedDownloadBytes > 0 ? expectedDownloadBytes : nil
        presentation.failure = nil
        present(presentation)
    }
    private func present(_ presentation: AppUpdatePresentation) {
        let firstPresentation = updatePresentation == nil
        if firstPresentation { mainUpdatePresentationApproved = false }
        updatePresentation = presentation
        if firstPresentation { onPresentUpdate?() }
    }

    func willInstallVersion(_ version: String) {
        guard isAvailable, recordsInstalledVersions else { return }
        defaults.set(currentVersion, forKey: "TSXLastLaunchedReleaseVersion")
        defaults.set(version, forKey: "TSXPendingInstalledReleaseVersion")
    }

    func prepareInstalledReleaseNotes() {
        guard isAvailable, recordsInstalledVersions, currentVersion != "—" else { return }
        let previous = defaults.string(forKey: "TSXLastLaunchedReleaseVersion")
            ?? (hadLegacyLaunch ? "1.0.0" : nil)
        let pending = defaults.string(forKey: "TSXPendingInstalledReleaseVersion")
        let acknowledged = defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion")
        let upgraded = previous.map { SUStandardVersionComparator().compareVersion(currentVersion, toVersion: $0) == .orderedDescending } ?? false
        if acknowledged != currentVersion, pending == currentVersion || upgraded {
            defaults.set(currentVersion, forKey: "TSXPendingInstalledReleaseVersion")
            pendingReleaseNotesVersion = currentVersion
            mainReleaseNotesPresentation = .installed(version: currentVersion)
            onPresentReleaseNotes?()
        }
        defaults.set(currentVersion, forKey: "TSXLastLaunchedReleaseVersion")
    }

    func acknowledgeInstalledReleaseNotes() {
        guard let version = pendingReleaseNotesVersion else { return }
        defaults.set(version, forKey: "TSXAcknowledgedReleaseNotesVersion")
        defaults.removeObject(forKey: "TSXPendingInstalledReleaseVersion")
        pendingReleaseNotesVersion = nil
    }

    func showRecentReleaseNotes(in location: AppUpdateLocation = .settings) {
        switch location {
        case .settings: releaseNotesPresentation = .recent
        case .mainWindow: mainReleaseNotesPresentation = .recent
        }
    }
    func dismissReleaseNotes(in location: AppUpdateLocation = .settings, acknowledging: Bool = true) {
        switch location {
        case .settings:
            releaseNotesPresentation = nil
        case .mainWindow:
            if acknowledging { acknowledgeInstalledReleaseNotes() }
            mainReleaseNotesPresentation = nil
        }
    }
    func loadReleaseNotes(force: Bool = false) async {
        guard schedule.confirmed, !automaticSession, !withdrawing, mode != .manual || isChecking,
              (isChecking || releaseNotesPresentation == .recent || mainReleaseNotesPresentation == .recent || force),
              releases.needsLoad(force: force), startBackend() else { return }
        if isChecking {
            releases.beginLoading(force: force)
            return
        }
        guard canCheckForUpdates, releases.beginLoading(force: force) else { return }
        automaticSession = false
        checkOrigin = .releaseNotes; sessionPhase = .checking
        lastCheckFailed = false
        beginProbe()
    }

    func loadedAppcast(_ appcast: SUAppcast) {
        // A failed signature can still reach this callback in Sparkle's recovery
        // mode. Never display that remote content, even if Sparkle finds an update.
        recordFeedVerification(appcast.signingValidationStatus == .succeeded)
        releases.receive(appcast.items.map(AppcastReleaseNotes.init), status: appcast.signingValidationStatus)
    }

    func configureMenuItem(_ item: NSMenuItem) {
        item.title = L10n.string("Check for updates")
        item.target = menuTarget
        item.action = #selector(AppUpdateMenuTarget.checkForUpdates)
        item.isEnabled = canCheckForUpdates
    }

    #if TRANSLATEX_VISUAL_QA
    static func visualReview(previewInstalledNotes: Bool = false, shortReleaseNotes: Bool = false,
                             previewAvailableUpdate: Bool = false, compactReleaseNotes: Bool = false,
                             checkOutcome: String? = nil) -> AppUpdateController {
        let backend = VisualReviewAppUpdater(fixtureVersion: compactReleaseNotes ? "1.1.2" : "1.0.1",
                                             checkOutcome: checkOutcome)
        let entries: [AppRelease]? = compactReleaseNotes ? [
            .init(version: "1.1.2", publishedAt: Date().addingTimeInterval(-10_800), notes: """
            ## 中文
            - **更清晰的更新提示** 弹窗居中显示，版本对比与操作一目了然。
            - **更容易发现新版本** 翻译窗口新增更新入口，悬停时暂停动画。
            - **更稳定的窗口切换** 修复焦点回跳，关闭更新弹窗后保留翻译内容。
            ### 安装与说明
            这段构造的安装说明不应出现在弹窗中。
            ## English
            - **Clearer update prompts** Centered dialogs keep versions and actions easy to find.
            - **Updates are easier to discover** The translation window has an update entry that pauses on hover.
            - **More stable window switching** Dismissing an update preserves your translation and keyboard focus.
            ### Installation and notes
            These constructed installation notes must not appear in the dialog.
            """, url: URL(string: "https://github.com/uuthings/tsx/releases/tag/v1.1.2")!),
            .init(version: "1.1.1", publishedAt: Date().addingTimeInterval(-93_600), notes: """
            ## 中文
            - **双栏编辑更连贯** 清空一侧时同步移除旧内容，重新输入后可继续双向翻译。
            - **避免旧结果重新填入** 清空时取消旧翻译，保留中文输入法的正常组合输入。
            ## English
            - **Smoother editing in both panes** Clearing one side removes stale text before translation resumes.
            - **Old results stay cleared** Clearing cancels pending translations and preserves composed input.
            """, url: URL(string: "https://github.com/uuthings/tsx/releases/tag/v1.1.1")!)
        ] : previewAvailableUpdate ? [.init(version: "1.0.1", publishedAt: .distantPast,
            notes: "## 中文\n- 修复双栏编辑中删除到空白后，另一侧仍残留旧内容的问题；清空后重新输入可继续双向翻译。\n- 清空时取消旧翻译，避免延迟返回的结果重新填入；保留中文输入法组合输入的正常行为。\n## English\n- Clear stale content in the other pane when editing down to an empty draft. Typing again resumes translation.\n- Cancel pending translations when clearing the draft while preserving composed text input.",
            url: URL(string: "https://github.com/uuthings/tsx/releases")!)] : shortReleaseNotes ? [.init(version: "1.0.0", publishedAt: .distantPast,
            notes: "## 中文\n- 更新说明现在显示在翻译窗口中央。\n- 改善服务切换图标的圆角。\n## English\n- Release notes now appear over the translation workspace.\n- Service action icons have softer corners.",
            url: URL(string: "https://github.com/uuthings/tsx/releases/tag/v1.0.0")!)] : nil
        let previewDefaults = UserDefaults(suiteName: "TSX.UpdateVisualFixture")!
        previewDefaults.setVolatileDomain(["UpdatePolicyMode": "notify"], forName: UserDefaults.argumentDomain)
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          currentVersion: compactReleaseNotes ? (previewAvailableUpdate ? "1.1.1" : "1.1.2") : "1.0.0", defaults: previewDefaults, recordsInstalledVersions: false,
                                          backend: backend, releases: AppReleaseNotesStore(entries: entries, allowsNetworkLoading: false))
        backend.owner = updates
        if previewInstalledNotes, updates.releases.entries.contains(where: { $0.version == updates.currentVersion }) {
            _ = updates.startBackend()
            updates.mainReleaseNotesPresentation = .installed(version: updates.currentVersion)
        } else { updates.start() }
        return updates
    }
    #endif
}

@MainActor
private final class AppUpdateMenuTarget: NSObject, NSMenuItemValidation {
    private weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }
    @objc func checkForUpdates() { owner?.checkForUpdates() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { owner?.canCheckForUpdates == true }
}

#if TRANSLATEX_VISUAL_QA
/// An isolated presentation fixture. No Sparkle object, network request,
/// install operation, preference write or application termination is performed.
@MainActor
private final class VisualReviewAppUpdater: AppUpdaterBackend {
    weak var owner: AppUpdateController?
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    private var simulation: Task<Void, Never>?
    // This candidate only exercises the UI; it is not a published release.
    private let fixtureVersion: String
    private let checkOutcome: String?
    init(fixtureVersion: String = "1.0.1", checkOutcome: String? = nil) {
        self.fixtureVersion = fixtureVersion
        self.checkOutcome = checkOutcome
    }

    func start() throws {}
    func checkInformation() {
        owner?.recordFeedVerification(true)
        owner?.foundUpdate(fixtureVersion)
        owner?.finishedCheck()
    }
    func checkUpdates() {
        guard let checkOutcome else { offerUpdate(); return }
        owner?.showUpdateCheck { [weak self] in
            self?.simulation?.cancel()
            self?.owner?.finishedCheck()
        }
        simulation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            switch checkOutcome {
            case "failed": owner?.updateErrored()
            case "current": owner?.updateNotFound()
            default: offerUpdate()
            }
            owner?.finishedCheck()
        }
    }
    private func offerUpdate() {
        owner?.offerUpdate(version: fixtureVersion, informationOnly: false, informationURL: nil,
                           userInitiated: true) { [weak self] choice in
            guard choice == .install, let self else { return }
            self.simulation = Task { [weak self] in await self?.simulateDownload() }
        }
    }
    private func simulateDownload() async {
        owner?.downloadStarted { [weak self] in self?.simulation?.cancel() }
        owner?.downloadExpected(100)
        for _ in 0..<5 {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            owner?.downloadReceived(20)
        }
        guard !Task.isCancelled else { return }
        owner?.extractionStarted()
        owner?.extractionProgress(1)
        owner?.readyToInstall { [weak self] choice in
            guard choice == .install else { return }
            self?.owner?.installing()
        }
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        owner?.installationDismissed()
        owner?.finishedCheck()
    }
}
#endif
