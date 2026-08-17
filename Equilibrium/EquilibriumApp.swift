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
                    minHeight: 520,
                    maxHeight: 520
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
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
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
