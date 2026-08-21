import Foundation
import UserNotifications

// Local streak-reminder notifications. No server / push is involved: we
// schedule local notifications ahead of time and lean on the fact that a
// streak can ONLY be extended from inside the app — studying flashcards,
// listening, and answering comprehension all funnel through
// FirebaseDeckService.saveStudySession. That means every time the user
// extends their streak we get an in-app moment to cancel that day's reminders
// immediately.
//
// Two reminders per day, both firing only while the streak still needs
// attention that day:
//   • Morning — a nudge to open the app and work on the flashcard deck.
//   • Evening — a "don't lose your streak" reminder, only if the user
//     hasn't already practiced that day.
// Both fire times are user-adjustable from the Profile screen (defaulting
// to 09:00 and 19:00); the pickers write the same UserDefaults keys read
// here, so UserDefaults stays the single source of truth.
//
// We can't run code at fire time to re-check "did they study today", so instead
// we schedule a rolling window of one-shot notifications for the next several
// days and reschedule aggressively: on every study, on foreground, and on
// background. Same-day reminders are dropped the instant the user practices;
// future days are pre-scheduled so reminders still fire even if the app is
// never opened, and are pruned as each day rolls into "today" and the user
// acts.
@MainActor
final class StreakReminderService {
    static let shared = StreakReminderService()
    private init() {}

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    // How many days ahead to pre-schedule one-shots so reminders keep firing
    // through a stretch where the app is never opened. Well under the 64
    // pending-notification limit even at two per day.
    private let windowDays = 7

    // Default fire times as minutes since midnight: the 09:00 morning nudge
    // and the 19:00 streak warning. Used until the user picks their own.
    static let defaultMorningMinutes = 9 * 60
    static let defaultEveningMinutes = 19 * 60

    private enum Key {
        static let enabled = "streakRemindersEnabled"
        static let lastActivityDay = "streakLastActivityDay"
        static let morningMinutes = "streakMorningMinutes"
        static let eveningMinutes = "streakEveningMinutes"
    }

    // User-chosen fire times, stored as minutes since midnight so a DatePicker
    // in Profile can drive them at hour+minute granularity. Read straight from
    // UserDefaults (Profile's @AppStorage writes the same keys), falling back
    // to the defaults when unset.
    private var morningMinutes: Int {
        defaults.object(forKey: Key.morningMinutes) as? Int ?? Self.defaultMorningMinutes
    }
    private var eveningMinutes: Int {
        defaults.object(forKey: Key.eveningMinutes) as? Int ?? Self.defaultEveningMinutes
    }

    // Master on/off, read straight from UserDefaults so the Profile toggle
    // (an @AppStorage on the same key) is the single source of truth.
    // Defaults ON — the reminders are the point of the feature.
    var isEnabled: Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? true
    }

    // Start-of-day of the most recent streak activity recorded on THIS device.
    // Stamped by recordActivityToday(); decides whether today's reminders are
    // still needed.
    private var lastActivityDay: Date? {
        get { defaults.object(forKey: Key.lastActivityDay) as? Date }
        set { defaults.set(newValue, forKey: Key.lastActivityDay) }
    }

    // MARK: - Public API

    // Ask for permission the first time we can (status == notDetermined), then
    // schedule. Safe to call on every foreground: iOS only shows the system
    // prompt on the first request; later calls just reschedule.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted { await reschedule() }
        } else {
            await reschedule()
        }
    }

    // The user just did a streak-eligible activity. Stamp today and drop any
    // now-unnecessary same-day reminders. Called from
    // FirebaseDeckService.saveStudySession on every successful save.
    func recordActivityToday() async {
        lastActivityDay = Calendar.current.startOfDay(for: Date())
        await reschedule()
    }

    // Reconciles the local "studied today" stamp against an authoritative
    // source (the Library's Firestore-derived practice history), so a
    // reinstall or a session studied on another device doesn't fire a
    // redundant reminder here. Then reschedules.
    func syncStudiedToday(_ studiedToday: Bool) async {
        if studiedToday {
            lastActivityDay = Calendar.current.startOfDay(for: Date())
        }
        await reschedule()
    }

    // Recomputes the entire pending set from current state. Idempotent — it
    // always clears our reminders first, so calling it repeatedly is safe.
    func reschedule() async {
        clearAll()
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        guard isEnabled, authorized else { return }
        scheduleWindow()
    }

    // MARK: - Scheduling

    private func scheduleWindow() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let studiedToday = lastActivityDay.map { cal.isDate($0, inSameDayAs: today) } ?? false

        for offset in 0..<windowDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let isToday = offset == 0
            // Today's reminders are unnecessary once the user has practiced.
            // Future days are always scheduled — the app will prune them as
            // each becomes "today" and the user acts (or lets them fire).
            if isToday, studiedToday { continue }
            scheduleReminder(
                on: day, minutesOfDay: morningMinutes, offset: offset, isToday: isToday, now: now,
                identifier: "\(Self.morningPrefix)\(offset)",
                title: L("Keep your streak alive 🔥"),
                body: L("Take a few minutes with your flashcards today.")
            )
            scheduleReminder(
                on: day, minutesOfDay: eveningMinutes, offset: offset, isToday: isToday, now: now,
                identifier: "\(Self.eveningPrefix)\(offset)",
                title: L("Don't break your streak"),
                body: L("You haven't practiced yet today — a quick review keeps your streak going.")
            )
        }
    }

    private func scheduleReminder(
        on day: Date,
        minutesOfDay: Int,
        offset: Int,
        isToday: Bool,
        now: Date,
        identifier: String,
        title: String,
        body: String
    ) {
        let cal = Calendar.current
        guard let fire = cal.date(
            bySettingHour: minutesOfDay / 60,
            minute: minutesOfDay % 60,
            second: 0,
            of: day
        ) else { return }
        // A fire time earlier today has already passed — skip it (only ever
        // possible for the offset-0 day).
        if isToday, fire <= now { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func clearAll() {
        let ids = (0..<windowDays).flatMap {
            ["\(Self.morningPrefix)\($0)", "\(Self.eveningPrefix)\($0)"]
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static let morningPrefix = "streak.morning."
    private static let eveningPrefix = "streak.evening."
}
