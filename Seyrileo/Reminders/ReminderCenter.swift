import Foundation
import Observation
import SeyrileoKit
import UserNotifications

/// Local programme reminders: rows in the database, notifications in iOS.
///
/// - Notification permission is asked only when the user sets the first reminder.
/// - Every change rebuilds Seyrileo's pending notifications from the database (`reconcile`), so
///   removed sources, ended programmes, new parental locks and a new app language are applied.
/// - A reminder for a locked channel never shows the channel or programme name: notifications
///   appear on the lock screen, outside parental controls.
/// - Tapping a notification opens the channel through `AppModel.playbackItem`, so the parental
///   gate applies there too.
@MainActor
@Observable
final class ReminderCenter {
    enum Permission: Equatable { case unknown, allowed, denied }

    private(set) var revision = 0
    private(set) var permission: Permission = .unknown

    @ObservationIgnored private var store: ReminderStore?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    /// Whether a channel's reminders must be masked (set by AppModel).
    @ObservationIgnored var isLocked: (MediaKey) async -> Bool = { _ in false }
    @ObservationIgnored private static let prefix = "reminder."

    func configure(store: ReminderStore) async {
        self.store = store
        await refreshPermission()
        await reconcile()
    }

    func refreshPermission() async {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = .allowed
        case .denied: permission = .denied
        default: permission = .unknown
        }
    }

    // MARK: - Reading

    func upcoming() async -> [ProgramReminder] {
        (try? await store?.upcoming()) ?? []
    }

    func reminder(for channel: MediaKey, start: Date) async -> ProgramReminder? {
        try? await store?.reminder(for: channel, start: start)
    }

    // MARK: - Changing

    /// Sets or removes the reminder for a programme. Returns an issue to show, or nil.
    func toggle(_ program: EPGProgram, channel: LiveChannel) async -> UserIssue? {
        guard let store else { return nil }
        if let existing = try? await store.reminder(for: channel.key, start: program.start) {
            await remove(existing)
            return nil
        }
        // Ask for permission only now, when the user wants a reminder.
        if permission != .allowed {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshPermission()
            guard granted else { return UserIssue.notificationsOff }
        }
        do {
            try await store.add(ProgramReminder(
                channel: channel.key, channelTitle: SourceCatalogModel.title(channel),
                programTitle: program.title.isEmpty ? String(app: "Untitled") : program.title,
                start: program.start, end: program.end))
        } catch {
            return UserIssue(error)
        }
        await reconcile()
        return nil
    }

    func remove(_ reminder: ProgramReminder) async {
        try? await store?.remove(reminder.id)
        await reconcile()
    }

    /// Makes iOS's pending notifications match the database.
    func reconcile() async {
        guard let store else { return }
        try? await store.pruneEnded()
        let reminders = (try? await store.upcoming()) ?? []
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        if permission == .allowed {
            let now = Date()
            for reminder in reminders where reminder.start > now {
                let masked = await isLocked(reminder.channel)
                try? await center.add(request(for: reminder, masked: masked, now: now))
            }
        }
        revision += 1
    }

    private func request(for reminder: ProgramReminder, masked: Bool, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let time = reminder.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.app))
        if masked {
            content.title = String(app: "A programme is starting soon")
            content.body = String(app: "It's on a locked channel. The parental PIN is needed to watch.")
        } else {
            content.title = reminder.programTitle
            content.body = String(app: "Starts at \(time) on \(reminder.channelTitle).")
        }
        content.sound = .default
        content.threadIdentifier = "reminders"
        content.userInfo = ["sourceID": reminder.channel.providerID.uuidString, "channel": reminder.channel.remoteID]
        let delay = max(1, reminder.fireDate(now: now).timeIntervalSince(now))
        return UNNotificationRequest(
            identifier: reminder.notificationID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
    }
}

/// Receives notification taps (also when a tap launches the app) and hands them to the app.
@MainActor
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// The channel a tapped reminder points to, until the app has opened it.
    var pendingChannel: MediaKey?

    override init() {
        super.init()
        #if DEBUG
        // `-SeyrileoOpenChannel <sourceUUID>:<channelID>`: behave as if a reminder was tapped
        // (simulator checks only; automation cannot tap system banners reliably).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-SeyrileoOpenChannel"), index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let source = UUID(uuidString: parts[0]) {
                pendingChannel = MediaKey(providerID: source, kind: .live, remoteID: parts[1])
            }
        }
        #endif
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let source = (info["sourceID"] as? String).flatMap(UUID.init(uuidString:)),
              let channel = info["channel"] as? String
        else { return }
        await MainActor.run {
            pendingChannel = MediaKey(providerID: source, kind: .live, remoteID: channel)
        }
    }
}

extension UserIssue {
    static let notificationsOff = UserIssue(
        title: "Notifications are turned off",
        detail: "Seyrileo can't remind you about programmes without notifications.",
        suggestions: ["Turn on notifications for Seyrileo in the iOS Settings app."], canRetry: false)
}
