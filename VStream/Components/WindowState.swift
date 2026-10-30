import AppKit
import SwiftUI

/// Tracks whether the hosting window is in full screen. Observation starts once the view is
/// actually in a window (it usually isn't yet when `makeNSView` runs).
private struct FullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            onChange?(window.styleMask.contains(.fullScreen))
            let center = NotificationCenter.default
            tokens = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(true) }
                },
                center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(false) }
                },
            ]
        }

        isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = { value in
            #if DEBUG
            FileHandle.standardError.write(Data("[debug] fullscreen=\(value)\n".utf8))
            #endif
            if isFullScreen != value { isFullScreen = value }
        }
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {}
}

extension EnvironmentValues {
    @Entry var isFullScreen = false
}

extension View {
    func trackingFullScreen(_ isFullScreen: Binding<Bool>) -> some View {
        background(FullScreenObserver(isFullScreen: isFullScreen))
    }
}
