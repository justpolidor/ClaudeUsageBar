import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var service = UsageService()
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var codexService = CodexUsageService()
    @StateObject private var appUpdater = AppUpdater()
    @AppStorage(UsageProvider.menuBarDefaultsKey) private var menuBarProvider = UsageProvider.claude

    /// Falls back to Claude whenever Codex is picked but has nothing to show,
    /// so the icon never sits empty because of a setting the user forgot.
    private var iconProvider: UsageProvider {
        (menuBarProvider == .codex && codexService.usage != nil) ? .codex : .claude
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                service: service,
                historyService: historyService,
                notificationService: notificationService,
                codexService: codexService,
                appUpdater: appUpdater
            )
        } label: {
            Image(nsImage: service.isAuthenticated
                ? renderIcon(
                    pct5h: iconProvider == .codex ? codexService.pct5h : service.pct5h,
                    pct7d: iconProvider == .codex ? codexService.pct7d : service.pct7d,
                    provider: iconProvider
                )
                : renderUnauthenticatedIcon()
            )
                .task {
                    // Auto-mark existing users as setup-complete
                    if service.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    historyService.loadHistory()
                    service.historyService = historyService
                    service.notificationService = notificationService
                    service.codexService = codexService
                    await codexService.refresh()
                    service.startPolling()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                service: service,
                notificationService: notificationService,
                codexService: codexService,
                appUpdater: appUpdater
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
