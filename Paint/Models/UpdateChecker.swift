import AppKit

/// A dotted version, compared numerically rather than as text so 1.0.10 sorts
/// after 1.0.9.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]
    /// A pre-release suffix such as `beta.1` in `1.1.0-beta.1`, or nil.
    let prerelease: String?

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        let split = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = split.first, !core.isEmpty else { return nil }
        prerelease = split.count > 1 ? String(split[1]) : nil

        let parsed = core.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        components = parsed.map { $0! }
    }

    var description: String {
        let core = components.map(String.init).joined(separator: ".")
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    /// Both `<` and `==` come from here. Deriving them separately is how you
    /// end up with 1.0 being neither less than, equal to, nor greater than
    /// 1.0.0 — which quietly breaks every comparison built on top.
    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> ComparisonResult {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            // Missing trailing components read as zero, so 1.0 == 1.0.0.
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        // Same numbers: a pre-release comes before its final release.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, .some): return .orderedDescending
        case (.some, nil): return .orderedAscending
        case let (.some(a), .some(b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }
}

/// Tells you when a newer Paint has been published, and stops there.
///
/// It never downloads or installs anything: the only action it offers is
/// opening the release page in your browser, so nothing is ever executed on
/// your Mac that you didn't fetch and unzip yourself.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let feedURL = URL(string: "https://api.github.com/repos/ilmakio/paint-macos/releases/latest")!
    private let downloadPage = URL(string: "https://paint.makio.app")!
    private let checkInterval: TimeInterval = 60 * 60 * 24

    private enum Key {
        static let lastCheck = "lastUpdateCheck"
        static let automatic = "automaticUpdateChecks"
        static let skipped = "skippedUpdateVersion"
    }

    private var isChecking = false

    private init() {
        UserDefaults.standard.register(defaults: [Key.automatic: true])
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.bool(forKey: Key.automatic) }
        set { UserDefaults.standard.set(newValue, forKey: Key.automatic) }
    }

    var currentVersion: AppVersion {
        let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return AppVersion(string ?? "0") ?? AppVersion("0")!
    }

    struct Release {
        let version: AppVersion
        let pageURL: URL
    }

    /// The pure part: turn GitHub's JSON into a release. Kept separate so it
    /// can be tested without touching the network.
    static func parseRelease(from data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag)
        else { return nil }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:))
        return Release(version: version, pageURL: page
            ?? URL(string: "https://github.com/ilmakio/paint-macos/releases/latest")!)
    }

    // MARK: Entry points

    /// Called at launch. Silent unless there is something newer, and at most
    /// once a day.
    func checkInBackgroundIfDue() {
        guard checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date
        if let last, Date().timeIntervalSince(last) < checkInterval { return }
        check(userInitiated: false)
    }

    /// Called from the menu. Always reports, including "you're up to date".
    @objc func checkForUpdates(_ sender: Any?) {
        check(userInitiated: true)
    }

    // MARK: Work

    private func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Paint/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // Never serve a stale answer from the URL cache for an explicit check.
        request.cachePolicy = userInitiated ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                UserDefaults.standard.set(Date(), forKey: Key.lastCheck)

                if let error {
                    if userInitiated { self.presentFailure(error.localizedDescription) }
                    return
                }
                guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                      let data, let release = UpdateChecker.parseRelease(from: data)
                else {
                    if userInitiated {
                        self.presentFailure("GitHub didn’t return a release Paint could read.")
                    }
                    return
                }

                if release.version > self.currentVersion {
                    let skipped = UserDefaults.standard.string(forKey: Key.skipped)
                    if !userInitiated, skipped == release.version.description { return }
                    self.presentUpdate(release)
                } else if userInitiated {
                    self.presentUpToDate()
                }
            }
        }.resume()
    }

    // MARK: Alerts

    private func presentUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Paint \(release.version) is available"
        alert.informativeText = """
        You’re running \(currentVersion). Paint doesn’t install updates for itself — \
        the button below just opens the download page in your browser.
        """
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(downloadPage)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version.description, forKey: Key.skipped)
        default:
            break
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You’re up to date"
        alert.informativeText = "Paint \(currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailure(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t check for updates"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases…")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(downloadPage)
        }
    }
}
