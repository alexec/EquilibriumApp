import SwiftUI

@main
struct EquilibriumApp: App {
    @StateObject private var viewModel = WorkHistoryViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 380, idealWidth: 480, maxWidth: 900, minHeight: 480, maxHeight: 480)
                .background(WindowChromeRemover())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Replaces the default "About Equilibrium" item with one that
            // opens the standard panel but with our "why I built this"
            // story as its credits text, instead of a custom in-window
            // popover living behind a "?" button.
            CommandGroup(replacing: .appInfo) {
                Button("About Equilibrium") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: AboutStory.text,
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor,
                                ]
                            )
                        ]
                    )
                }
            }
        }

        MenuBarExtra {
            MenuBarStatusView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The compact label shown in the menu bar: today's hours / remaining budget.
private struct MenuBarLabel: View {
    @ObservedObject var viewModel: WorkHistoryViewModel

    var body: some View {
        let today = viewModel.span(for: Date())?.effectiveHours ?? 0
        let remaining = viewModel.remainingWeeklyHours()

        let todayText = HoursFormat.string(today)
        let remainingText = remaining >= 0
            ? "\(HoursFormat.string(remaining)) left"
            : "+\(HoursFormat.string(-remaining))"

        Text("\(todayText)  \(remainingText)")
            .font(.system(size: 12, weight: .medium, design: .rounded))
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
