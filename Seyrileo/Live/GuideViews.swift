import SeyrileoKit
import SwiftUI

/// Now/next under a channel name, with a progress bar. Loads lazily when the row appears and
/// refreshes itself when the current programme ends.
struct NowNextLine: View {
    let channel: LiveChannel
    let catalog: SourceCatalogModel
    var compact = false
    @State private var nowNext: NowNext?
    @State private var loaded = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let nowNext {
                VStack(alignment: .leading, spacing: 3) {
                    if let now = nowNext.now {
                        HStack(spacing: 4) {
                            Text("Now").fontWeight(.semibold).foregroundStyle(.tint)
                            Text(verbatim: now.title.isEmpty ? "—" : now.title).lineLimit(1)
                        }
                        ProgressLine(fraction: now.progress(at: context.date), tint: .brandAmber)
                            .frame(maxWidth: compact ? 140 : 220)
                    }
                    if let next = nowNext.next {
                        HStack(spacing: 4) {
                            Text(next.start, format: .dateTime.hour().minute())
                            Text(verbatim: next.title.isEmpty ? "—" : next.title).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .task(id: nowNext.now?.end ?? nowNext.next?.start) {
                    // Reload once the current programme is over.
                    guard let boundary = nowNext.now?.end ?? nowNext.next?.start else { return }
                    let wait = boundary.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait + 1)) }
                    guard !Task.isCancelled else { return }
                    self.nowNext = await catalog.nowNext(for: channel)
                }
            } else if loaded {
                Text("No guide information right now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(channel.key)|\(catalog.epgRevision)") {
            nowNext = await catalog.nowNext(for: channel)
            loaded = true
        }
        .accessibilityElement(children: .combine)
    }
}

/// Several days of programmes for one channel, in the user's time zone.
struct ChannelGuideView: View {
    let channel: LiveChannel
    let catalog: SourceCatalogModel
    var onWatch: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [EPGProgram]?
    @State private var issue: UserIssue?
    @State private var selectedDay: Date?
    @State private var now = Date()
    @Environment(AppModel.self) private var app
    /// Start times of this channel's programmes that have a reminder.
    @State private var remindedStarts: Set<Date> = []
    @State private var reminderIssue: UserIssue?

    private var days: [Date] {
        let calendar = Calendar.current
        return Array(Set((programs ?? []).map { calendar.startOfDay(for: $0.start) })).sorted()
    }

    /// The chosen day, else today, else the closest day that has programmes.
    private var day: Date {
        if let selectedDay { return selectedDay }
        let today = Calendar.current.startOfDay(for: now)
        if days.contains(today) || days.isEmpty { return today }
        return days.min { abs($0.timeIntervalSince(today)) < abs($1.timeIntervalSince(today)) } ?? today
    }

    private var dayPrograms: [EPGProgram] {
        let calendar = Calendar.current
        let start = day
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // Programmes overlapping the day, so one running past midnight appears on both days.
        return (programs ?? []).filter { $0.end > start && $0.start < end }
    }

    var body: some View {
        NavigationStack {
            Group {
                if channel.epgChannelID == nil {
                    ContentUnavailableView("No guide for this channel", systemImage: "calendar.badge.exclamationmark", description: Text("The provider doesn't publish programme information for this channel."))
                } else if let issue {
                    BrandList { IssueView(issue: issue) { Task { await load() } } }
                } else if let programs {
                    if programs.isEmpty {
                        ContentUnavailableView("No guide data", systemImage: "calendar", description: Text("The provider returned no programmes for this channel right now."))
                    } else {
                        guideList
                    }
                } else {
                    PawLoader(size: 30)
                }
            }
            .navigationTitle(SourceCatalogModel.title(channel))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let onWatch {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                            onWatch()
                        } label: {
                            Label("Watch", systemImage: "play.fill")
                        }
                    }
                }
            }
        }
        .task { await load() }
        .task(id: app.reminders.revision) {
            remindedStarts = Set(await app.reminders.upcoming().filter { $0.channel == channel.key }.map(\.start))
        }
        .issueAlert($reminderIssue)
        .proPaywall()
    }

    private var guideList: some View {
        ScrollViewReader { proxy in
            BrandList {
                if days.count > 1 {
                    Section {
                        ScrollViewReader { chips in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(days, id: \.self) { date in
                                        Button {
                                            selectedDay = date
                                        } label: {
                                            Text(Self.dayLabel(date))
                                                .fontWeight(date == day ? .semibold : .regular)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(date == day ? Color.accent.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(date == day ? .isSelected : [])
                                        .id(date)
                                    }
                                }
                            }
                            .onAppear { chips.scrollTo(day, anchor: .center) }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                Section {
                    ForEach(dayPrograms) { program in
                        ProgramRow(
                            program: program, now: now, hasReminder: remindedStarts.contains(program.start),
                            toggleReminder: {
                                // Removing an existing reminder is always allowed.
                                let isSet = remindedStarts.contains(program.start)
                                guard isSet || app.pro.require(app.pro.isPro, for: .reminders) else { return }
                                Task { reminderIssue = await app.reminders.toggle(program, channel: channel) }
                            }
                        )
                        .id(program.id)
                    }
                } footer: {
                    Text("Times are shown in your time zone (\(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)).")
                }
            }
            .task(id: day) {
                // Bring the programme on air (today) into view once the rows exist.
                guard let current = dayPrograms.first(where: { $0.isOnAir(at: now) }) else { return }
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo(current.id, anchor: .center)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    now = Date()
                }
            }
        }
    }

    private func load() async {
        issue = nil
        do {
            programs = try await catalog.guide(for: channel)
        } catch {
            issue = UserIssue(error)
        }
    }

    static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(app: "Today") }
        if calendar.isDateInTomorrow(date) { return String(app: "Tomorrow") }
        if calendar.isDateInYesterday(date) { return String(app: "Yesterday") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

private struct ProgramRow: View {
    let program: EPGProgram
    let now: Date
    var hasReminder = false
    var toggleReminder: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            details
            Spacer(minLength: 0)
            // Only upcoming programmes can have a reminder.
            if program.start > now {
                Button(action: toggleReminder) {
                    Image(systemName: hasReminder ? "bell.fill" : "bell")
                        .font(.body)
                        .foregroundStyle(hasReminder ? Color.accent : .secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(hasReminder ? Text("Remove reminder") : Text("Remind me"))
                .accessibilityAddTraits(hasReminder ? .isSelected : [])
            }
        }
    }

    private var details: some View {
        let onAir = program.isOnAir(at: now)
        let past = program.end <= now
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(program.start, format: .dateTime.hour().minute())–\(program.end, format: .dateTime.hour().minute())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(onAir ? Color.accent : .secondary)
                if onAir {
                    Text("Now").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accent.opacity(0.25), in: Capsule())
                }
            }
            Text(verbatim: program.title.isEmpty ? "—" : program.title).font(.body.weight(onAir ? .semibold : .regular))
            if let summary = program.summary {
                Text(verbatim: summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if onAir { ProgressLine(fraction: program.progress(at: now)) }
        }
        .opacity(past ? 0.5 : 1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Every channel the provider maps to guide data, with now/next. Wider layout on iPad.
struct GuideOverviewView: View {
    let catalog: SourceCatalogModel
    @Environment(AppModel.self) private var app
    @State private var loaded: [LiveChannel]?
    /// Locked channels are left out of the guide while parental controls are locked.
    private var channels: [LiveChannel]? { loaded?.filter { !app.parental.isMasked($0) } }
    @State private var guideChannel: LiveChannel?
    @State private var player = PlayerLauncher()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        BrandList {
            switch channels {
            case nil:
                LoadingRow(text: "Loading…")
            case let list? where list.isEmpty:
                ContentUnavailableView("No guide data", systemImage: "calendar", description: Text("This source doesn't publish programme information for its channels."))
            case let list?:
                Section {
                    ForEach(list) { channel in
                        HStack(alignment: .top, spacing: 12) {
                            Button { player.play(channel, in: list, catalog: catalog) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Monogram(text: channel.name)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(SourceCatalogModel.title(channel)).lineLimit(1)
                                        NowNextLine(channel: channel, catalog: catalog, compact: sizeClass != .regular)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { guideChannel = channel } label: {
                                Image(systemName: "calendar").frame(width: 36, height: 36)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("TV guide"))
                        }
                    }
                } footer: {
                    Text("\(list.count) channels have programme information.")
                }
            }
        }
        .navigationTitle("Guide")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: catalog.catalogRevision) { loaded = await catalog.channelsWithGuide() }
        .sheet(item: $guideChannel) { channel in
            ChannelGuideView(channel: channel, catalog: catalog) {
                player.play(channel, in: channels ?? [channel], catalog: catalog)
            }
        }
        .playerPresentation(player, catalog: catalog)
    }
}
