import SwiftUI

#if os(macOS)
import AppKit

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

#else
import UIKit

/// UIKit can't swap a view's backing layer, so mpv's CAMetalLayer is a sublayer kept at the
/// view's bounds.
final class MPVVideoUIView: UIView {
    private let model: PlayerModel

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        layer.addSublayer(model.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = bounds.size
        guard size.width > 1, size.height > 1, scale > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        model.layer.contentsScale = scale
        model.layer.frame = bounds
        model.layer.drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        CATransaction.commit()
        model.surfaceDidBecomeReady()
    }
}

public struct MPVVideoView: UIViewRepresentable {
    private let model: PlayerModel

    public init(model: PlayerModel) {
        self.model = model
    }

    public func makeUIView(context: Context) -> UIView {
        MPVVideoUIView(model: model)
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
