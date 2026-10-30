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

/// Reports the hosting window's full-screen state: once when attached (so views created while
/// the window is already full screen start correct) and on every enter/exit of that window.
private struct FullScreenReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let report: @MainActor @Sendable (Bool) -> Void = { [weak self] value in self?.onChange?(value) }
            DispatchQueue.main.async { [weak window] in
                if let window { report(window.styleMask.contains(.fullScreen)) }
            }
            let center = NotificationCenter.default
            tokens = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { report(true) }
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { report(false) }
                },
            ]
        }

        isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }
}

extension View {
    /// Calls `action` with the hosting window's full-screen state, initially and on change.
    func onFullScreenChange(_ action: @escaping (Bool) -> Void) -> some View {
        background(FullScreenReader(onChange: action))
    }
}
