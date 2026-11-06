import Foundation
let company = ProcessInfo.processInfo.environment["COMPANY"] ?? "Wülfe Company"
for path in CommandLine.arguments.dropFirst() {
    do { try PDFScrubber(company: company).scrub(url: URL(fileURLWithPath: path)); print("OK", path) }
    catch { print("FAIL", path, error.localizedDescription) }
}
