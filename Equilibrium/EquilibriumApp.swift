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
        // Here rather than in the window, because the menu bar outlives the
        // window: this app is one you close and leave running in the tray,
        // and hanging the refresh timers off `ContentView`'s appearance
        // meant closing the window froze the tray's line and stopped the
        // power monitor recording sleeps. See `startAutoRefresh`.
        viewModel.startAutoRefresh()
    }

    /// The day panel's contribution to the window's width. It's always on
    /// screen and holds text at a fixed, readable measure, so this is a
    /// constant — the window is simply that much wider than the chart.
    private let panelWidth = DayDetailPanel.width + 16

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(viewModel: viewModel)
                // Sized so the chart has room for seven day columns, and
                // then left free to grow.
                //
                // Every bound carries the day panel's fixed width on top of
                // what the chart and the inbox need, so resizing changes
                // what those two get and leaves the panel alone.
                //
                // This used to pin both dimensions — one height, and a
                // narrow band of widths — with a ceiling that existed to
                // shrink windows macOS restored at an old, wider size. That
                // was liveable with two columns and isn't with three: an
                // inbox, a week and a day panel side by side want more room
                // on a large display and less on a laptop, and which is
                // which is the reader's call rather than this file's. The
                // ceilings that remain are generous enough to be a guard
                // against a restored window from another Mac rather than a
                // limit anyone meets by dragging.
                .frame(
                    minWidth: 340 + panelWidth + SideColumn.width + 16,
                    idealWidth: 460 + panelWidth + SideColumn.width + 16,
                    maxWidth: 1000 + panelWidth + SideColumn.width + 16,
                    // Tall enough that a day's summary and its three spoken
                    // fields sit on screen together, with the people strip
                    // below them. Extra height goes to the three columns,
                    // which is what the inbox wants — more of it visible.
                    minHeight: 560 + PeopleStrip.height,
                    idealHeight: 600 + PeopleStrip.height + 24,
                    maxHeight: 1400
                )
                .background(WindowChromeRemover())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Settings belongs in the app menu, at ⌘,, which is where every
            // Mac user already looks for it. It used to be a gear in the
            // window's top corner — one more thing competing for attention
            // in a window that now holds an inbox, a week and a day.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    viewModel.showsPreferences = true
                    MainWindow.present { }
                }
                .keyboardShortcut(",", modifiers: .command)
            }

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
