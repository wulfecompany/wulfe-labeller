import SwiftUI
import AppKit
import UniformTypeIdentifiers

let defaultCompanyName = "Wülfe Company"
let companyNameKey = "companyName"

#if !SNAPSHOT
@main
#endif
struct WulfeLabellerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LabellerModel.shared
    @StateObject private var updater = Updater.shared

    var body: some Scene {
        Window("Wülfe Labeller", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(userInitiated: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quiet check on launch: only speaks up if a newer version exists.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            Updater.shared.checkForUpdates(userInitiated: false)
        }
    }

    /// PDFs dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in LabellerModel.shared.process(urls) }
    }
}

// MARK: - Model

@MainActor
final class LabellerModel: ObservableObject {
    static let shared = LabellerModel()

    struct Failure: Identifiable {
        let id = UUID()
        let fileName: String
        let message: String
    }

    struct Result: Identifiable {
        let id = UUID()
        let updated: Int
        let failures: [Failure]
    }

    @Published var isWorking = false
    @Published var result: Result?
    private var hideTask: Task<Void, Never>?

    var companyName: String {
        let stored = UserDefaults.standard.string(forKey: companyNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultCompanyName : stored
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Update"
        panel.message = "Choose PDFs to relabel. They'll be updated in place."
        if panel.runModal() == .OK { process(panel.urls) }
    }

    func process(_ urls: [URL]) {
        guard !isWorking else { return }
        let pdfs = Self.collectPDFs(from: urls)
        guard !pdfs.isEmpty else {
            show(Result(updated: 0, failures: [Failure(fileName: "No PDFs found", message: "Drop one or more .pdf files.")]))
            return
        }
        isWorking = true
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { result = nil }
        let company = companyName

        Task.detached(priority: .userInitiated) {
            var updated = 0
            var failures: [Failure] = []
            for url in pdfs {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try PDFScrubber(company: company).scrub(url: url)
                    updated += 1
                } catch {
                    failures.append(Failure(fileName: url.lastPathComponent, message: error.localizedDescription))
                }
            }
            let outcome = Result(updated: updated, failures: failures)
            await MainActor.run {
                self.isWorking = false
                self.show(outcome)
            }
        }
    }

    private func show(_ outcome: Result) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { result = outcome }
        hideTask?.cancel()
        guard outcome.failures.isEmpty else { return } // keep errors on screen until the next drop
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) { self?.result = nil }
        }
    }

    func dismissResult() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { result = nil }
    }

    nonisolated static func collectPDFs(from urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = items?.nextObject() as? URL {
                    if item.pathExtension.lowercased() == "pdf" { out.append(item) }
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                out.append(url)
            }
        }
        return out
    }
}
