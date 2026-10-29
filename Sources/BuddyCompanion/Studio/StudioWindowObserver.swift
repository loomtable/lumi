import AppKit
import SwiftUI

/// Tells the Studio model whether its window is key and on the active Space (visible, not fully
/// covered), from the window's own notifications.
struct StudioWindowObserver: NSViewRepresentable {
    let model: StudioModel

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.model = model }

    final class ObserverView: NSView {
        weak var model: StudioModel?
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didChangeOcclusionStateNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            guard let window, let model else { return }
            model.windowKey = window.isKeyWindow
            model.windowOnScreen = window.occlusionState.contains(.visible)
        }
    }
}
