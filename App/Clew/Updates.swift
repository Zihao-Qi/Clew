import AppKit
import ClewCore
import Foundation

/// The opt-in update check and the About pane's state (SPEC 2026-11-13, "About and
/// updates"). The rules are Core's `UpdateState`; this keeps it in UserDefaults (it
/// belongs to this Mac, not to Clew's data), runs the checks and tells the views.
@MainActor @Observable
final class Updates {
    static let repository = URL(string: "https://github.com/Zihao-Qi/Clew")!
    static let author = URL(string: "https://github.com/Zihao-Qi")!
    static let latestPage = URL(string: "https://github.com/Zihao-Qi/Clew/releases/latest")!
    static let brewCommand = "brew update && brew upgrade --cask clew"

    static func releasePage(_ version: AppVersion) -> URL {
        URL(string: "https://github.com/Zihao-Qi/Clew/releases/tag/\(version.tag)")!
    }

    /// The running app, from its bundle ("1.5.0" and "6").
    let running: AppVersion?
    let versionText: String
    let buildText: String

    private(set) var state: UpdateState
    private(set) var checking = false
    /// What Check Now found ("Clew is up to date.", "Couldn't check for updates.").
    private(set) var message: String?
    /// The gear asked for About; Settings takes it when it appears or is open.
    var paneRequest: SettingsView.Pane?
    /// Settings is open on About and not minimized: a release found now is seen.
    var aboutShowing = false {
        didSet { if aboutShowing, !oldValue { update { $0.aboutShown(running: running) } } }
    }

    var available: AppVersion? { state.available(running: running) }
    var showsDot: Bool { state.showsDot(running: running) }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var fetch: @MainActor () async -> String? = { await UpdateChecker.latestTag() }
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wake: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        versionText = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        buildText = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        running = AppVersion(running: versionText)
        state = Self.load(defaults)
    }

    /// The real app only: checks on launch, on wake and every hour, when due.
    func start() {
        checkIfDue()
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.checkIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    func setOn(_ on: Bool) {
        update { $0.isOn = on }
        if on { checkIfDue() }
    }

    func checkIfDue() {
        guard state.automaticCheckDue(now: now()) else { return }
        Task { await check(manual: false) }
    }

    func checkNow() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        if manual { message = nil }
        update { $0.began(now: now()) }
        let tag = await fetch()
        var outcome = UpdateState.Outcome.failed
        update { outcome = $0.finished(tag: tag, now: now(), running: running, aboutShowing: aboutShowing) }
        checking = false
        guard manual else { return }   // an automatic check that fails says nothing
        switch outcome {
        case .upToDate: message = String(localized: "Clew is up to date.")
        case .available: message = nil   // About shows "Clew 1.5.1 is available."
        case .failed: message = String(localized: "Couldn't check for updates.")
        }
    }

    private func update(_ change: (inout UpdateState) -> Void) {
        change(&state)
        Self.save(state, defaults)
    }

    // MARK: Stored per Mac

    private enum Key {
        static let on = "updateCheck.on"
        static let lastAttempt = "updateCheck.lastAttempt"
        static let lastSuccess = "updateCheck.lastSuccess"
        static let latest = "updateCheck.latest"
        static let seen = "updateCheck.seen"
    }

    private static func load(_ d: UserDefaults) -> UpdateState {
        UpdateState(isOn: d.bool(forKey: Key.on),
                    lastAttempt: d.object(forKey: Key.lastAttempt) as? Date,
                    lastSuccess: d.object(forKey: Key.lastSuccess) as? Date,
                    latest: (d.string(forKey: Key.latest)).flatMap(AppVersion.init(tag:)),
                    seen: (d.string(forKey: Key.seen)).flatMap(AppVersion.init(tag:)))
    }

    private static func save(_ s: UpdateState, _ d: UserDefaults) {
        d.set(s.isOn, forKey: Key.on)
        d.set(s.lastAttempt, forKey: Key.lastAttempt)
        d.set(s.lastSuccess, forKey: Key.lastSuccess)
        d.set(s.latest?.tag, forKey: Key.latest)
        d.set(s.seen?.tag, forKey: Key.seen)
    }
}

/// The one request (SPEC 2026-11-13): GitHub's latest release, read for its tag only.
/// No cookies, no cache, a plain user agent, nothing about the user.
enum UpdateChecker {
    static let endpoint = URL(string: "https://api.github.com/repos/Zihao-Qi/Clew/releases/latest")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "Clew", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: config)
    }()

    private struct Release: Decodable { let tag_name: String }

    /// The tag, or nil for no network, any reply but 200, or a body without one.
    static func latestTag() async -> String? {
        do {
            let (data, response) = try await session.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Release.self, from: data).tag_name
        } catch {
            return nil
        }
    }
}
