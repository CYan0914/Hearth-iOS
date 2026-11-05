import AuthenticationServices
import SwiftUI

/// The only way in. Sign in with Apple and nothing else.
///
/// No email/password, no Google, no guest mode: an account exists to hold a
/// maintenance history, and a guest account that cannot be recovered is a way to
/// lose one. Offering fewer doors also means fewer ways to end up with a user
/// whose records are split across two identities.
struct SignInView: View {
    @EnvironmentObject private var session: SessionStore

    @StateObject private var coordinator = AppleSignInCoordinator()
    @State private var isWorking = false
    @State private var error: String?

    /// Drives the button's style. See `signInButton` for why the style is not a
    /// constant.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 48)

                HearthMark(size: 88)
                    .padding(.bottom, 20)

                Text("Hearth")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 6)

                Text("Your home's maintenance record,\nkept in one place.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 36)

                // Three claims, each one something the app actually does, in the
                // order the user will meet them. A generic feature list here
                // would waste the one screen where the user is deciding.
                VStack(alignment: .leading, spacing: 18) {
                    Promise(
                        icon: "camera.viewfinder",
                        title: "Photograph a nameplate",
                        detail: "The brand and model are read for you, and the right maintenance schedule is set up immediately."
                    )
                    Promise(
                        icon: "calendar.badge.clock",
                        title: "Get told when it's due",
                        detail: "Filters, vents, hoses, alarms. Reminders arrive before something fails, not after."
                    )
                    Promise(
                        icon: "doc.text.magnifyingglass",
                        title: "Keep the receipts",
                        detail: "Every repair and service in one history you can hand to an insurer or a buyer."
                    )
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 40)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                }

                signInButton

                Text("Hearth keeps your inventory private. No ads, no tracking, and you can delete your account and its data from Settings at any time.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
            }
            // 展开态限宽。这里原来只有 `.frame(maxWidth: .infinity)` —— 那是
            // 撑满而不是限宽，很容易被当成「已经处理过了」。iPhone Duo 展开态
            // 内屏约 1000pt，隐私说明那一段会被拉成一整行。560 是阅读宽度上限；
            // 第二个 `.frame(maxWidth: .infinity)` 负责限宽之后把它居中。
            // 折叠态可用宽本就不到 560，行为与改前逐像素相同。
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Apple's own button, wired to both halves of the exchange.
    ///
    /// The style is `.black` or `.white` -- the two Apple provides -- chosen
    /// against the current colour scheme, because the background here is
    /// `systemGroupedBackground` and that is near-black in dark mode. A fixed
    /// `.black` therefore had no visible edge at all in dark mode: the button
    /// dissolved into the page and only its white wordmark floated, reading as
    /// a caption rather than something tappable. App Review said exactly that
    /// (Guideline 4, September 2026), so the style now tracks the scheme.
    private var signInButton: some View {
        SignInWithAppleButton(.signIn) { request in
            coordinator.prepare(request)
        } onCompletion: { result in
            Task {
                isWorking = true
                error = nil
                defer { isWorking = false }
                do {
                    let session = try await coordinator.exchange(result)
                    await self.session.signedIn(session: session)
                } catch SignInError.cancelled {
                    // The user closed the sheet. Not an error, and showing one
                    // would be scolding them for changing their mind.
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .disabled(isWorking)
        .opacity(isWorking ? 0.55 : 1)
        .overlay {
            if isWorking {
                // Inverted against the button, which is itself inverted
                // against the page -- so the spinner stays visible in both
                // schemes.
                ProgressView().tint(colorScheme == .dark ? .black : .white)
            }
        }
        .padding(.horizontal, 28)
    }
}

private struct Promise: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(Theme.ember)
                .frame(width: 26)
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
