import SwiftUI

struct UpgradeView: View {
    var onDismiss: () -> Void
    @State private var selectedPlan = "annual"

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.yellow)
                Text("Upgrade to Pro")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Unlock the full power of OpenTolk Cloud")
                    .foregroundStyle(.secondary)
            }

            // Feature comparison
            VStack(spacing: 0) {
                comparisonHeader
                Divider()
                comparisonRow("Words / month", free: "5,000", pro: "Unlimited")
                Divider()
                comparisonRow("Max recording", free: "30s", pro: "120s")
                Divider()
                comparisonRow("Languages", free: "English", pro: "All Whisper-supported")
                Divider()
                comparisonRow("History entries", free: "20", pro: "50")
            }
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Own-key note
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Have your own API key? Use it for free forever with no limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Pricing
            VStack(spacing: 6) {
                Text("Most Popular")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.blue)
                    .clipShape(Capsule())
                    .opacity(selectedPlan == "annual" ? 1 : 0)

                HStack(spacing: 12) {
                    pricingCard(plan: "monthly", title: "Monthly", price: "$4.99", period: "/month")
                    pricingCard(plan: "annual", title: "Annual", price: "$39.99", period: "/year")
                    pricingCard(plan: "lifetime", title: "Lifetime", price: "$79.99", period: "once")
                }
            }

            // CTA
            Button {
                if AuthManager.shared.isSignedIn {
                    SubscriptionManager.shared.openCheckout(plan: selectedPlan)
                } else {
                    // Require sign-in before checkout
                    NSWorkspace.shared.open(URL(string: "opentolk://auth")!)
                }
            } label: {
                HStack {
                    Image(systemName: "creditcard")
                    Text("Continue to Checkout")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Dismiss
            Button("Maybe later") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(24)
        .frame(width: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var comparisonHeader: some View {
        HStack {
            Text("Feature")
                .font(.caption)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Free")
                .font(.caption)
                .fontWeight(.semibold)
                .frame(width: 80)
            Text("Pro")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)
                .frame(width: 100)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func comparisonRow(_ feature: String, free: String, pro: String) -> some View {
        HStack {
            Text(feature)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(free)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80)
            Text(pro)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.blue)
                .frame(width: 100)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func pricingCard(plan: String, title: String, price: String, period: String) -> some View {
        let isSelected = selectedPlan == plan
        return VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text(price)
                .font(.title3)
                .fontWeight(.bold)
            Text(period)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? .blue.opacity(0.2) : .clear, radius: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedPlan = plan
            }
        }
    }
}

struct UpgradeSuccessView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Welcome to Pro!")
                .font(.title2)
                .fontWeight(.bold)

            Text("Thank you for upgrading. You now have\nunlimited dictation, longer recordings,\nand access to all languages.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Text("Start Dictating")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 420, height: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
