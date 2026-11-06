import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer version, then downloads it, swaps it in and relaunches.
///
/// A release is expected to be tagged `vX.Y[.Z]` with a `.zip` asset containing the `.app`.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    nonisolated static let repository = "wulfecompany/wulfe-labeller"

    struct Release {
        let version: String
        let notes: String
        let assetURL: URL
        let pageURL: URL?
    }

    enum UpdateError: LocalizedError {
        case badResponse, noAsset, badArchive, notWritable(URL)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "Couldn't reach GitHub."
            case .noAsset: return "The latest release has no app download attached."
            case .badArchive: return "The downloaded update doesn't look like Wülfe Labeller."
            case .notWritable(let url): return "Wülfe Labeller can't replace itself at \(url.deletingLastPathComponent().path). Move the app to Applications and try again."
            }
        }
    }

    /// Shown as a small status chip at the top of the window while updating.
    @Published var status: String?
    private var isBusy = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Checking

    /// `userInitiated` = from the menu: also reports "up to date" and errors.
    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let release = try await Self.fetchLatestRelease()
                if Self.isVersion(release.version, newerThan: Self.currentVersion) {
                    promptToInstall(release)
                } else if userInitiated {
                    alert("You're up to date", "Wülfe Labeller \(Self.currentVersion) is the latest version.")
                }
            } catch {
                if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    nonisolated static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WulfeLabeller/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError.badResponse }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString), url.host == "github.com" else { throw UpdateError.noAsset }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", assetURL: url,
                       pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    private func promptToInstall(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "A new version of Wülfe Labeller is available"
        var info = "Version \(release.version) is available — you have \(Self.currentVersion)."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(600)) }
        alert.informativeText = info
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isBusy = true
        withAnimation { status = "Downloading update…" }
        Task {
            do {
                let appURL = Bundle.main.bundleURL
                try await Self.downloadAndInstall(release, replacing: appURL) { message in
                    Task { @MainActor in withAnimation { self.status = message } }
                }
                Self.relaunch(appURL)
            } catch {
                withAnimation { status = nil }
                isBusy = false
                let fail = NSAlert()
                fail.messageText = "Update failed"
                fail.informativeText = error.localizedDescription
                fail.addButton(withTitle: "OK")
                if release.pageURL != nil { fail.addButton(withTitle: "Open Download Page") }
                if fail.runModal() == .alertSecondButtonReturn, let page = release.pageURL { NSWorkspace.shared.open(page) }
            }
        }
    }

    /// Downloads the release zip, checks it, and replaces the app bundle at `appURL`.
    nonisolated static func downloadAndInstall(_ release: Release, replacing appURL: URL,
                                               progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
              !appURL.path.contains("/AppTranslocation/") else { throw UpdateError.notWritable(appURL) }

        let (download, response) = try await URLSession.shared.download(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        progress("Installing update…")

        let work = fm.temporaryDirectory.appendingPathComponent("WulfeLabellerUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: download, to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("unzipped").path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.badArchive }

        let unzipped = work.appendingPathComponent("unzipped")
        guard let newApp = try fm.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              newVersion == release.version
        else { throw UpdateError.badArchive }

        // Check the code signature is intact (catches corrupted downloads).
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", newApp.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw UpdateError.badArchive }

        removexattr(newApp.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        _ = try fm.replaceItemAt(appURL, withItemAt: newApp, backupItemName: nil, options: [])
    }

    /// Waits for this process to quit, then opens the (new) app again.
    private static func relaunch(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, appURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
