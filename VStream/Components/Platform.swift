import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few system calls that differ between the Mac and iPhone/iPad apps.
enum Platform {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Opens a URL in its default app (browser, YouTube…).
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension Color {
    /// The window/page background the hero and detail backdrops fade into.
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

#if os(iOS)
import AuthenticationServices

/// Shows an OAuth page inside the app. Opening Safari would suspend the app, and with it the
/// loopback server that catches Trakt's `http://localhost` redirect; an in-app web session keeps
/// the app in the foreground. The server completes the sign-in, then `finish()` closes the sheet.
@MainActor
enum SignInBrowser {
    private static var session: ASWebAuthenticationSession?
    private static let anchor = PresentationAnchor()

    static func open(_ url: URL) {
        session?.cancel()
        // The callback scheme never fires (the redirect is http://localhost); it's only required.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("vstream")) { _, _ in }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    static func finish() {
        session?.cancel()
        session = nil
    }

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first { $0.isKeyWindow } ?? ASPresentationAnchor()
            }
        }
    }
}
#else
/// On the Mac the browser opens normally; the loopback server keeps running.
@MainActor
enum SignInBrowser {
    static func open(_ url: URL) { Platform.open(url) }
    static func finish() {}
}
#endif

#if os(iOS)
/// Pages hide the navigation bar (they draw their own back button), which also turns off UIKit's
/// swipe-from-the-edge to go back. Re-enable it whenever there's a page to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer == interactivePopGestureRecognizer ? viewControllers.count > 1 : true
    }
}
#endif
