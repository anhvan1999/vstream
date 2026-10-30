import AppKit
import SwiftUI

/// Layer-hosting view whose backing layer is mpv's CAMetalLayer.
final class MPVVideoNSView: NSView {
    private let model: PlayerModel

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        layer = model.layer
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        model.layer.contentsScale = scale
        model.layer.frame = bounds
        model.layer.drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        CATransaction.commit()
        model.surfaceDidBecomeReady()
    }
}

public struct MPVVideoView: NSViewRepresentable {
    private let model: PlayerModel

    public init(model: PlayerModel) {
        self.model = model
    }

    public func makeNSView(context: Context) -> NSView {
        MPVVideoNSView(model: model)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
