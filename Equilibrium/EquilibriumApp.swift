import SwiftUI
import UserNotifications

@main
struct EquilibriumApp: App {
    // No default value: `init()` below builds the one instance and installs
    // it via `_viewModel`, so a default here would be dead weight.
    @StateObject private var viewModel: WorkHistoryViewModel
    /// Retained for the app lifetime so UNUserNotificationCenter's weak
    /// delegate pointer stays valid.
    private let notificationRouter: NotificationRouter

    init() {
        let viewModel = WorkHistoryViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        notificationRouter = NotificationRouter { action in
            // Captures the same instance the StateObject will own.
            viewModel.handleNotificationAction(action)
        }
        UNUserNotificationCenter.current().delegate = notificationRouter
        DailyIntentionNotifier.reschedule(preferences: viewModel.preferences)
    }

    /// The day panel's contribution to the window's width. It's always on
    /// screen, so this is a constant — the window is simply that much wider
    /// than the chart it holds.
    private let panelWidth = DayDetailPanel.width + 16

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(viewModel: viewModel)
                // Sized for seven day columns, not fourteen: at 420pt each
                // column is ~44pt, comfortably more than the 28pt an 18pt
                // bar and its workday track need. The ceiling is what
                // shrinks windows macOS restores at the old two-week width —
                // without it they'd stay needlessly wide, with the week's
                // bars stranded far apart.
                //
                // Every bound carries the day panel's width on top of that,
                // so resizing changes what the chart gets and leaves the
                // panel alone — it holds text at a fixed, readable measure.
                .frame(
                    minWidth: 360 + panelWidth,
                    idealWidth: 420 + panelWidth,
                    maxWidth: 560 + panelWidth,
                    // Tall enough that a day's summary and its three spoken
                    // fields sit on screen together: the panel is permanent
                    // furniture, and scrolling it to reach the check-in is
                    // the thing this height buys off.
                    minHeight: 600,
                    maxHeight: 600
                )
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
                .background(OpenWindowBinder(router: notificationRouter))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Shows the main window, raising the one that exists rather than adding
/// another.
///
/// `openWindow(id:)` appends a window to a `WindowGroup` every time it's
/// called, so a notification tap, a menu bar click and a reminder over the
/// course of a day left three identical windows stacked on top of each
/// other, each with its own panel.
enum MainWindow {
    @MainActor
    static func present(orOpen open: () -> Void) {
        // SwiftUI names a `WindowGroup`'s windows after the group's id;
        // anything else on screen belongs to the menu bar extra or a panel.
        let existing = NSApp.windows.first { window in
            window.identifier?.rawValue.hasPrefix("main") == true
        }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Hooks `openWindow` into `NotificationRouter` from a scene that always
/// hosts a SwiftUI environment (the menu bar extra).
private struct OpenWindowBinder: View {
    let router: NotificationRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                router.openMainWindow = {
                    MainWindow.present { openWindow(id: "main") }
                }
            }
    }
}

/// The compact label shown in the menu bar: hours left to work today, and
/// what's next in the diary.
///
/// The line itself is built by the view model (`menuBarText`) rather than
/// here. A `MenuBarExtra` label doesn't follow an observed object — a view
/// built in it renders once and keeps what it was first given — so reading
/// a published string in the App's own body is what makes it change.
///
/// The scales earn their place twice over: a bare figure in the menu bar
/// belongs to no app in particular, and there's something to aim the
/// pointer at when the number reads "0h".
private struct MenuBarLabel: View {
    @ObservedObject var viewModel: WorkHistoryViewModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "scalemass")
            Text(viewModel.menuBarText)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        // One element, not a symbol read out beside a number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.menuBarAccessibilityLabel)
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

            // SwiftUI brings up two windows of the group at launch — seen as
            // `main-AppWindow-1` and `-2`, both visible, one behind the
            // other, each with its own day panel. Nothing in the app asks
            // for the second, and one is all this app has any use for, so a
            // later arrival stands down in favour of the first.
            let mains = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
            if mains.count > 1, let first = mains.first, window !== first {
                window.close()
                return
            }

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
