import AppKit
import Combine
import Sparkle

/// Only the user driver is customized. Sparkle's signed appcast, archive
/// verification, privileged installer and normal AppKit termination stay intact.
@MainActor
final class SparkleAppUpdater: NSObject, AppUpdaterBackend {
    private let updater: SPUUpdater
    private let updateDelegate: AppSparkleDelegate
    private let userDriver: AppSparkleUserDriver
    private var subscriptions = Set<AnyCancellable>()
    private weak var owner: AppUpdateController?

    init(owner: AppUpdateController) {
        self.owner = owner
        updateDelegate = AppSparkleDelegate(owner: owner)
        userDriver = AppSparkleUserDriver(owner: owner)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: updateDelegate)
        super.init()
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak owner] _ in
            MainActor.assumeIsolated { owner?.refreshUpdaterState() }
        }.store(in: &subscriptions)

    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    func start() throws {
        updater.sendsSystemProfile = false
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        try updater.start()
    }
    func checkInformation() { updater.checkForUpdateInformation() }
    func checkUpdates() { updater.checkForUpdates() }
    @objc func menuCheckForUpdates() { owner?.checkForUpdates() }
}

@MainActor
private final class AppSparkleDelegate: NSObject, SPUUpdaterDelegate {
    private weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // The application schedules signed probes and authorizes downloads separately.
        if updateCheck == .updatesInBackground {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "Update scheduling is managed by TSX."])
        }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded else {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))
        }
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) { owner?.loadedAppcast(appcast) }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.foundUpdate(item.displayVersionString, publishedAt: item.date, build: item.versionString, downloadable: !item.isInformationOnlyUpdate, informationURL: item.infoURL)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if owner?.rejectsUnsignedResult == false { owner?.foundNoUpdate() }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { owner?.checkAborted(error) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) { owner?.finishedCheck(error: error) }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { owner?.willInstallVersion(item.displayVersionString) }


}

@MainActor
private final class AppSparkleUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { owner?.showUpdateCheck(cancellation: cancellation) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.dismiss); return }
        owner.offerUpdate(version: appcastItem.displayVersionString, informationOnly: appcastItem.isInformationOnlyUpdate,
                          informationURL: appcastItem.infoURL, publishedAt: appcastItem.date,
                          downloadSize: appcastItem.contentLength,
                          build: appcastItem.versionString, resumed: state.stage == .installing, userInitiated: state.userInitiated, reply: reply)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release history uses the verified appcast description. Sparkle's
        // downloaded HTML is never executed inside the settings interface.
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if owner?.rejectsUnsignedResult == true {
            owner?.updateErrored(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue)))
        } else { owner?.updateNotFound() }
        acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.updateErrored(error); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { owner?.downloadStarted(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { owner?.downloadExpected(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { owner?.downloadReceived(length) }
    func showDownloadDidStartExtractingUpdate() { owner?.extractionStarted() }
    func showExtractionReceivedProgress(_ progress: Double) { owner?.extractionProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.skip); return }
        owner.readyToInstall(reply: reply)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner?.installing(retry: applicationTerminated ? nil : retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { owner?.installationDismissed() }
    func showUpdateInFocus() { owner?.focusUpdate() }
}
