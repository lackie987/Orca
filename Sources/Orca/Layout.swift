import AppKit

/// Auto Layout helpers shared by the window, the splash and the settings panel.
enum Layout {
    /// Adds each view to `container` and pins it to all four edges, letting Auto Layout size it.
    ///
    /// Adds in argument order, so the first view ends up furthest back.
    static func fill(_ views: NSView..., in container: NSView) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }
}
