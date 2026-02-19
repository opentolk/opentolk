import SwiftUI

struct GmailConnectSection: View {
    @State private var isConnected = false
    @State private var connectedEmail: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gmail Account")
                .font(.subheadline)
                .fontWeight(.medium)

            if isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.body)
                    Text(connectedEmail ?? "Connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Disconnect") {
                        GmailAuthManager.shared.disconnect()
                        isConnected = false
                        connectedEmail = nil
                    }
                    .font(.subheadline)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button(action: connectGmail) {
                            HStack(spacing: 4) {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Connect Gmail")
                            }
                        }
                        .disabled(isLoading)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear { refreshState() }
    }

    private func refreshState() {
        Task { @MainActor in
            isConnected = GmailAuthManager.shared.isConnected
            connectedEmail = GmailAuthManager.shared.connectedEmail
        }
    }

    private func connectGmail() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                try await GmailAuthManager.shared.connect()
                isConnected = GmailAuthManager.shared.isConnected
                connectedEmail = GmailAuthManager.shared.connectedEmail
            } catch GmailAuthError.cancelled {
                // User cancelled — no error message
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
