import StoreKit
import SwiftUI

/// The upgrade screen.
///
/// It states what Pro is in the order a homeowner would care about: the
/// insurance report first, then the whole maintenance library, then the
/// ceilings. The ceiling that is worth money is not the asset count -- nobody
/// photographs their twentieth appliance and feels relief -- it is the export.
/// "What is in my house, in writing" is the thing an insurer asks for and the
/// thing this app can hand over, so it leads.
struct PaywallView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    /// Owned by the app, so the transaction listener is already running by the
    /// time this screen appears, and so a renewal seen at launch and a purchase
    /// made here go through the same object.
    @EnvironmentObject private var store: PurchaseStore

    /// Which plan is preselected. Yearly by default: it is the one worth
    /// recommending, and a default of monthly would quietly cost the user more
    /// for the same thing.
    @State private var selectedID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    benefits
                    if let message = store.message {
                        ErrorBanner(message: message)
                    }
                    plans
                    footer
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hearth Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await store.load() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything in your home, in writing")
                .font(.title2.weight(.semibold))
            Text(planSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var planSubtitle: String {
        if session.user?.plan == "pro" {
            return "You are subscribed. Thank you."
        }
        return "Free covers three things. Pro covers the house."
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            Benefit(
                icon: "doc.text.magnifyingglass",
                title: "Insurance inventory (PDF)",
                detail: "A printable list of everything you own, with values, serial numbers and photos. The document an insurer asks for after a fire, ready before you need it."
            )
            Benefit(
                icon: "wrench.and.screwdriver",
                title: "The whole maintenance library",
                detail: "All 39 schedules, including the seasonal and professional ones. Free keeps the 12 that cover safety and the most common appliances."
            )
            Benefit(
                icon: "shippingbox",
                title: "Every asset and every photo",
                detail: "No ceiling on how much you record. Free holds 3 things with 3 photos each."
            )
        }
    }

    @ViewBuilder
    private var plans: some View {
        switch store.loadState {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView().padding(.vertical, 40)
                Spacer()
            }
        case .failed(let reason):
            VStack(spacing: 12) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await store.load() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        case .loaded:
            VStack(spacing: 10) {
                ForEach(store.products, id: \.id) { product in
                    PlanRow(
                        product: product,
                        selected: selectedID == product.id || (selectedID == nil && isRecommended(product)),
                        busy: store.purchasingProductID == product.id
                    )
                    .onTapGesture { selectedID = product.id }
                }

                Button {
                    Task { await buy() }
                } label: {
                    Text(store.restoring ? "Restoring…" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedProduct == nil || store.purchasingProductID != nil || store.restoring)
                .padding(.top, 6)

                Button("Restore Purchases") {
                    Task { await store.restore(accountToken: session.user?.accountToken) }
                }
                .font(.footnote)
                .disabled(store.restoring || store.purchasingProductID != nil)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(disclosure)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link("Terms", destination: URL(string: "https://hearthlegal.taomindapp.com/terms")!)
                Link("Privacy", destination: URL(string: "https://hearthlegal.taomindapp.com/privacy")!)
            }
            .font(.caption2)
        }
    }

    /// Apple requires the renewal terms next to the button, in the app, before
    /// purchase -- not only on a website. Built from the product StoreKit
    /// actually returned so the period and price cannot contradict the store.
    private var disclosure: String {
        guard let product = selectedProduct else {
            return "Payment is charged to your Apple Account. Cancel any time in Settings."
        }
        if product.subscription == nil {
            return "One-time purchase. Charged to your Apple Account. Not a subscription."
        }
        return "\(product.priceText) \(product.periodText). Payment is charged to your Apple Account at confirmation. Subscriptions renew automatically unless cancelled at least 24 hours before the period ends. Manage or cancel in your Apple Account settings."
    }

    // MARK: - Actions

    private var selectedProduct: Product? {
        if let selectedID, let match = store.products.first(where: { $0.id == selectedID }) {
            return match
        }
        return store.products.first(where: isRecommended) ?? store.products.first
    }

    /// Yearly is the default selection.
    private func isRecommended(_ product: Product) -> Bool {
        product.id == "com.cyan0914.hearth.pro.yearly"
    }

    private func buy() async {
        guard let product = selectedProduct else { return }
        let unlocked = await store.purchase(product, accountToken: session.user?.accountToken)
        if unlocked {
            // The plan lives on the server, so the app only learns about it by
            // asking again.
            await session.refresh()
            dismiss()
        }
    }
}

// MARK: - Pieces

private struct Benefit: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PlanRow: View {
    let product: Product
    let selected: Bool
    let busy: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(product.planTitle).font(.subheadline.weight(.semibold))
                Text(product.periodText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if busy {
                ProgressView()
            } else {
                Text(product.priceText).font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}
