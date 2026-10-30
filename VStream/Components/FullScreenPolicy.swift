#if os(macOS)
import AppKit
import SwiftUI

/// Sets whether the hosting window may enter full screen. SwiftUI rewrites `collectionBehavior`
/// after the view joins the window and again around full-screen transitions (it dropped
/// `.fullScreenPrimary` while the player was full screen, disabling the green button and
/// `toggleFullScreen`), so the policy is re-applied on key, resize and full-screen changes.
private struct FullScreenPolicy: NSViewRepresentable {
    let allowed: Bool

    final class PolicyView: NSView {
        var allowed = true
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // Next turn: SwiftUI updates the window after these notifications too.
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        func apply() {
            guard let window else { return }
            if allowed {
                window.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
                window.collectionBehavior.insert(.fullScreenPrimary)
            } else {
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
        }

        isolated deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
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
    let onChange: (Bool, NSWindow) -> Void

    final class ReaderView: NSView {
        var onChange: ((Bool, NSWindow) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let report: @MainActor @Sendable (Bool) -> Void = { [weak self] value in
                guard let self, let window = self.window else { return }
                self.onChange?(value, window)
            }
            DispatchQueue.main.async { [weak self] in
                if let window = self?.window { report(window.styleMask.contains(.fullScreen)) }
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
    /// Calls `action` with the hosting window and its full-screen state, initially and on change.
    func onFullScreenChange(_ action: @escaping (Bool, NSWindow) -> Void) -> some View {
        background(FullScreenReader(onChange: action))
    }
}
#else
import SwiftUI

extension View {
    /// Windows are always full screen on iPhone/iPad.
    func fullScreenAllowed(_ allowed: Bool) -> some View { self }
}
#endif
