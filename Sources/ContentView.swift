import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LabellerModel
    @EnvironmentObject private var updater: Updater
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            DropCard(isTargeted: isTargeted, isWorking: model.isWorking) {
                model.presentOpenPanel()
            }

            VStack {
                if let status = updater.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if let result = model.result {
                    ResultChip(result: result) { model.dismissResult() }
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            model.process(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isTargeted = targeted }
        }
    }
}

// MARK: - Drop card

private struct DropCard: View {
    var isTargeted: Bool
    var isWorking: Bool
    var open: () -> Void

    @Environment(\.colorScheme) private var scheme
    private let shape = RoundedRectangle(cornerRadius: 68, style: .continuous)

    var body: some View {
        ZStack {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.62).opacity(0.38), .clear],
                                       center: UnitPoint(x: 0.45, y: 0.4), startRadius: 0, endRadius: 260)
                    )
                )
                .overlay(
                    shape.fill(
                        RadialGradient(colors: [Color(red: 0.85, green: 0.65, blue: 0.95).opacity(0.28), .clear],
                                       center: UnitPoint(x: 0.75, y: 0.65), startRadius: 0, endRadius: 220)
                    )
                )
                .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.18 : 0.75), lineWidth: 1))
                .shadow(color: Color(red: 1, green: 0.3, blue: 0.4).opacity(isTargeted ? 0.5 : 0.28), radius: isTargeted ? 70 : 55)
                .shadow(color: .black.opacity(0.10), radius: 24, y: 10)

            VStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Updating…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drop PDFs")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Text("or")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(.secondary)
                    Button(action: open) {
                        Text("Open")
                            .font(.system(size: 16, weight: .regular))
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(.white.opacity(scheme == .dark ? 0.12 : 0.45)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .frame(width: 300, height: 275)
        .scaleEffect(isTargeted ? 1.05 : 1)
    }
}

// MARK: - Result chip

private struct ResultChip: View {
    let result: LabellerModel.Result
    let dismiss: () -> Void
    @State private var showDetails = false

    private var hasFailures: Bool { !result.failures.isEmpty }

    private var message: String {
        let updated = "\(result.updated) \(result.updated == 1 ? "file" : "files") updated"
        if !hasFailures { return updated + "." }
        if result.updated == 0 && result.failures.count == 1 && result.failures[0].fileName == "No PDFs found" {
            return "No PDFs found."
        }
        return updated + ", \(result.failures.count) failed."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(hasFailures ? Color.orange : Color.green)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .medium))
            if hasFailures {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .onTapGesture { if hasFailures { showDetails.toggle() } }
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(result.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.fileName).font(.system(size: 12, weight: .semibold))
                        Text(failure.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 360, alignment: .leading)
        }
        .help(hasFailures ? "Click for details" : "")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(companyNameKey) private var companyName = defaultCompanyName

    var body: some View {
        Form {
            Section {
                TextField("Company name", text: $companyName, prompt: Text(defaultCompanyName))
            } footer: {
                Text("Used for the Author, Creator and Producer fields, and replaces any mention of Canva in a PDF's metadata.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Reset to Default") { companyName = defaultCompanyName }
                    .disabled(companyName == defaultCompanyName)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
