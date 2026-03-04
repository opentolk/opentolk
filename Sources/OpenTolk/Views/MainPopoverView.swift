import SwiftUI

struct MainPopoverView: View {
    @ObservedObject var viewModel: MainPopoverViewModel
    var onStartDictation: () -> Void
    var onOpenHistory: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // State indicator
            stateIndicator

            Divider()

            // Last transcription preview
            if let lastText = viewModel.lastTranscription {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last dictation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(lastText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy to clipboard")
                    }
                    Text(lastText.prefix(120) + (lastText.count > 120 ? "..." : ""))
                        .font(.body)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)

                Divider()
            }

            // Usage / provider info
            if viewModel.isCloudProvider {
                // Cloud provider: show usage counter
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.wordsUsed) / \(viewModel.wordsLimit) words this month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isPro {
                        Text("Pro")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(usageColor)
                            .frame(width: geo.size.width * usageProgress, height: 6)
                    }
                }
                .frame(height: 6)
            } else {
                // Own-key / local: show unlimited badge
                HStack {
                    Image(systemName: "infinity")
                        .foregroundStyle(.green)
                    Text("Unlimited \u{2014} using \(viewModel.providerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Divider()

            // Quick actions
            HStack(spacing: 16) {
                actionButton(icon: "clock", label: "History") {
                    onOpenHistory()
                }
                actionButton(icon: "gear", label: "Settings") {
                    onOpenSettings()
                }
                Spacer()
                if !viewModel.isPro {
                    Button {
                        viewModel.showUpgrade = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Pro")
                        }
                        .font(.caption)
                        .fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                }
                actionButton(icon: "power", label: "Quit") {
                    onQuit()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(.ultraThinMaterial)
    }

    // MARK: - State Indicator

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.appState {
        case .idle:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating, isActive: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready")
                        .font(.headline)
                    Text("Press Right Option to dictate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

        case .recording:
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating, isActive: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("Listening...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                WaveformView(isAnimating: true)
                    .frame(height: 32)
            }

        case .transcribing:
            HStack(spacing: 10) {
                Image(systemName: "hourglass")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribing")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Processing audio...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

        case .processing:
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running Plugin")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    Text(viewModel.activePluginName ?? "Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.body)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var usageProgress: CGFloat {
        guard viewModel.wordsLimit > 0 else { return 0 }
        return min(1.0, CGFloat(viewModel.wordsUsed) / CGFloat(viewModel.wordsLimit))
    }

    private var usageColor: Color {
        if usageProgress >= 1.0 { return .red }
        if usageProgress >= 0.8 { return .orange }
        return .blue
    }
}

// MARK: - ViewModel

final class MainPopoverViewModel: ObservableObject {
    @Published var appState: AppState = .idle
    @Published var lastTranscription: String?
    @Published var wordsUsed: Int = 0
    @Published var wordsLimit: Int = 5_000
    @Published var isPro: Bool = false
    @Published var showUpgrade: Bool = false
    @Published var isCloudProvider: Bool = true
    @Published var providerName: String = "OpenTolk Cloud"
    @Published var activePluginName: String?

    func refresh() {
        let entries = HistoryManager.shared.getAll()
        lastTranscription = entries.first?.text
        wordsUsed = UsageTracker.shared.wordsUsed()
        isPro = SubscriptionManager.shared.isPro

        let provider = Config.shared.selectedProvider
        isCloudProvider = provider == .cloud
        providerName = provider.displayName
        wordsLimit = (isPro || !isCloudProvider) ? Int.max : UsageTracker.freeTierWordLimit
    }
}
