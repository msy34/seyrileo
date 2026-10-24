import SeyrileoKit
import SwiftUI

/// Upcoming reminders of all sources, soonest first. Swipe to remove.
struct RemindersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var reminders: [ProgramReminder]?
    @State private var locked: Set<UUID> = []

    var body: some View {
        BrandList {
            if app.reminders.permission == .denied {
                Section {
                    Label("Notifications are turned off", systemImage: "bell.slash")
                    Button("Open notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("Seyrileo can't remind you about programmes without notifications.")
                }
            }
            switch reminders {
            case nil:
                LoadingRow(text: "Loading…")
            case let list? where list.isEmpty:
                ContentUnavailableView(
                    "No reminders", systemImage: "bell",
                    description: Text("Open a channel's TV guide and tap the bell next to an upcoming programme."))
            case let list?:
                Section {
                    ForEach(list) { reminder in
                        row(reminder)
                            .swipeActions {
                                Button("Remove", systemImage: "bell.slash", role: .destructive) {
                                    Task { await app.reminders.remove(reminder) }
                                }
                            }
                    }
                } footer: {
                    Text("You're notified 5 minutes before the programme starts. Reminders for locked channels don't show the channel or programme name.")
                }
            }
        }
        .navigationTitle("Reminders")
        .task(id: app.reminders.revision) {
            await app.reminders.refreshPermission()
            let list = await app.reminders.upcoming()
            var lockedIDs: Set<UUID> = []
            for reminder in list where app.parental.isRestricting {
                if await app.reminders.isLocked(reminder.channel) { lockedIDs.insert(reminder.id) }
            }
            locked = lockedIDs
            reminders = list
        }
    }

    @ViewBuilder
    private func row(_ reminder: ProgramReminder) -> some View {
        if locked.contains(reminder.id) {
            LockedRow(title: "Locked channel")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: reminder.programTitle).font(.body.weight(.semibold))
                Text(verbatim: reminder.channelTitle).font(.subheadline).foregroundStyle(.secondary)
                Text(reminder.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }
}
