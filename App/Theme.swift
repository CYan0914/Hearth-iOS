import SwiftUI

/// Design tokens, in one place.
///
/// Kept as an enum of static values rather than an environment-injected theme
/// object: the app has one look, and a token that can vary per screen is a token
/// that will.
///
/// Colors are defined in code rather than only in the asset catalog so the
/// semantic ones (priority, status) can be reasoned about next to the rules that
/// use them. The two that AppKit needs before SwiftUI exists -- the launch
/// background and the accent -- are also in `Assets.xcassets`, because
/// `Info.plist` and the system refer to them by name.
enum Theme {

    // MARK: - Palette

    /// Warm neutrals rather than pure gray. The subject is a home, and a
    /// blue-gray palette makes maintenance read as a sysadmin tool.
    static let ember = Color(red: 0.804, green: 0.412, blue: 0.353)
    static let emberSoft = Color(red: 0.910, green: 0.545, blue: 0.475)
    static let hearth = Color(red: 0.176, green: 0.137, blue: 0.118)

    /// Priority colors. `safety` is the only one that is a real alarm -- a dryer
    /// vent full of lint is a house fire, a filter is not -- so it is the only
    /// one that gets saturated red.
    static func priority(_ priority: String) -> Color {
        switch priority {
        case "safety": return .red
        case "high": return .orange
        default: return .secondary
        }
    }

    static func status(_ status: String) -> Color {
        switch status {
        case "active": return .green
        case "archived": return .secondary
        case "disposed": return .secondary
        default: return .secondary
        }
    }

    // MARK: - Metrics

    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 14
    static let gutter: CGFloat = 16
    static let sectionSpacing: CGFloat = 22

    // MARK: - Type

    /// The number that is the whole promise of the confirm screen ("6 tasks
    /// scheduled"), so it is sized to be the thing the eye lands on.
    static let bigNumber = Font.system(size: 40, weight: .semibold, design: .rounded)
    static let cardTitle = Font.headline
    static let cardMeta = Font.subheadline
    static let badge = Font.caption2.weight(.semibold)
}

// MARK: - Shared pieces

/// A small capsule label: "Safety", "Overdue", "Monthly".
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(Theme.badge)
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The card used for every list row and detail section.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// A full-width message for an empty list.
///
/// The action is part of the component because an empty state without one is a
/// dead end, and the asset list's empty state is the app's only chance to
/// explain what it is for.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Theme.ember.opacity(0.7))
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ember)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 24)
    }
}

/// An inline error banner. Used instead of an alert for anything the user can
/// retry, because an alert demands a dismissal and a banner does not.
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Try again", action: retry)
                        .font(.subheadline.weight(.medium))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
