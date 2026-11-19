import AppKit
import Combine
import Network

enum UpdateMode: String, CaseIterable {
    case manual, notify, install
}

/// Each app uses its own preferences domain. A failed attempt never changes the
/// last successful check, even if Sparkle updates its own timestamp.
@MainActor
final class UpdateSchedule {
    private let defaults: UserDefaults
    private let now: () -> Date
    private let monitorsNetwork: Bool
    private var online: Bool
    private var pathMonitor: NWPathMonitor?
    private var subscriptions = Set<AnyCancellable>()
    private var trigger: ((Bool) -> Void)?
    private(set) var mode: UpdateMode
    private(set) var confirmed: Bool
    var lastSuccess: Date? { defaults.object(forKey: "UpdateLastSuccess") as? Date }

    init(defaults: UserDefaults, legacyMode: UpdateMode, monitorsNetwork: Bool, now: @escaping () -> Date) {
        self.defaults = defaults
        self.now = now
        self.monitorsNetwork = monitorsNetwork
        online = !monitorsNetwork
        let saved = defaults.string(forKey: "UpdatePolicyMode").flatMap(UpdateMode.init)
        mode = saved ?? legacyMode
        confirmed = saved != nil
    }

    func select(_ value: UpdateMode) {
        mode = value
        confirmed = true
        defaults.set(value.rawValue, forKey: "UpdatePolicyMode")
    }

    func due(reconnected: Bool) -> Bool {
        guard confirmed, mode != .manual, online else { return false }
        let date = now()
        if let retry = defaults.object(forKey: "UpdateRetryAfter") as? Date {
            if retry <= date || retry.timeIntervalSince(date) > 4 * 3600 { return true }
            if reconnected, defaults.bool(forKey: "UpdateRetryOnReconnect"), !defaults.bool(forKey: "UpdateReconnectUsed") {
                defaults.set(true, forKey: "UpdateReconnectUsed")
                return true
            }
            return false
        }
        return lastSuccess.map { $0 > date || date.timeIntervalSince($0) >= 86400 } ?? true
    }

    func succeeded() {
        defaults.set(now(), forKey: "UpdateLastSuccess")
        for key in ["UpdateRetryCount", "UpdateRetryAfter", "UpdateRetryOnReconnect", "UpdateReconnectUsed"] {
            defaults.removeObject(forKey: key)
        }
    }

    func failed(network: Bool) {
        let date = now()
        let delays: [TimeInterval] = [900, 3600, 14400]
        let count = min(max(0, defaults.integer(forKey: "UpdateRetryCount")), delays.count - 1)
        defaults.set(count + 1, forKey: "UpdateRetryCount")
        defaults.set(date.addingTimeInterval(delays[count]), forKey: "UpdateRetryAfter")
        // A flapping connection must not convert repeated failures into a loop.
        defaults.set(network, forKey: "UpdateRetryOnReconnect")
    }

    func observe(_ trigger: @escaping (Bool) -> Void) {
        guard monitorsNetwork, self.trigger == nil else { return }
        self.trigger = trigger
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { _ in trigger(false) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in trigger(false) }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.stopMonitoringPath() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.monitorPath(afterWake: true) }.store(in: &subscriptions)
        monitorPath(afterWake: false)
    }

    private func stopMonitoringPath() {
        online = false
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func monitorPath(afterWake: Bool) {
        stopMonitoringPath()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        var receivedPath = afterWake
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            MainActor.assumeIsolated {
                guard let self, let monitor, self.pathMonitor === monitor else { return }
                let wasOnline = self.online
                self.online = path.status == .satisfied
                if self.online { self.trigger?(receivedPath && !wasOnline) }
                receivedPath = true
            }
        }
        monitor.start(queue: .main)
    }
}

extension UpdateMode {
    var titleKey: String {
        switch self {
        case .manual: "Manual only"
        case .notify: "Automatically check and notify"
        case .install: "Automatically download and install"
        }
    }
    var descriptionKey: String {
        switch self {
        case .manual: "Check only when you choose Check for updates."
        case .notify: "Check every 24 hours and mark new versions. You choose when to download."
        case .install: "Check every 24 hours, download updates and install when you quit."
        }
    }
}
