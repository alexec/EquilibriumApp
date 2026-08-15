import SwiftUI

@main
struct EquilibriumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 380, idealWidth: 480, maxWidth: 900, minHeight: 480, maxHeight: 480)
                .background(WindowChromeRemover())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Makes the title bar transparent and traffic-light-only (no title text),
/// so the content reaches the window's edges while the standard
/// close/minimize/zoom buttons remain visible and clickable in the corner.
/// The window is dragged via its background, since there's no title text
/// left to grab.
private struct WindowChromeRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear

            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 20
            window.contentView?.layer?.masksToBounds = true
            window.contentView?.superview?.wantsLayer = true
            window.contentView?.superview?.layer?.cornerRadius = 20
            window.contentView?.superview?.layer?.masksToBounds = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
