import AppKit
import SwiftUI

/// Tracks whether the hosting window is in full screen.
private struct FullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    final class Coordinator {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            isFullScreen = window.styleMask.contains(.fullScreen)
            let center = NotificationCenter.default
            let update: (Bool) -> (Notification) -> Void = { value in { _ in isFullScreen = value } }
            context.coordinator.tokens = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main, using: update(true)),
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main, using: update(false)),
            ]
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension EnvironmentValues {
    @Entry var isFullScreen = false
}

extension View {
    func trackingFullScreen(_ isFullScreen: Binding<Bool>) -> some View {
        background(FullScreenObserver(isFullScreen: isFullScreen))
    }
}
