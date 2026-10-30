import AppKit
import SwiftUI

/// Sets whether the hosting window may enter full screen. SwiftUI configures
/// `collectionBehavior` after the view joins the window, so the policy is applied on the next
/// run-loop turn and re-applied whenever the window becomes key.
private struct FullScreenPolicy: NSViewRepresentable {
    let allowed: Bool

    final class PolicyView: NSView {
        var allowed = true
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        func apply() {
            guard let window else { return }
            if allowed {
                window.collectionBehavior.remove(.fullScreenNone)
                window.collectionBehavior.insert(.fullScreenPrimary)
            } else {
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
        }

        isolated deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    func makeNSView(context: Context) -> PolicyView {
        let view = PolicyView()
        view.allowed = allowed
        return view
    }

    func updateNSView(_ nsView: PolicyView, context: Context) {
        nsView.allowed = allowed
        nsView.apply()
    }
}

extension View {
    /// Allows or forbids full screen for the window hosting this view.
    func fullScreenAllowed(_ allowed: Bool) -> some View {
        background(FullScreenPolicy(allowed: allowed))
    }
}
