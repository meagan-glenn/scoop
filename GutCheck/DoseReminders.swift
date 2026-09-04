import Foundation
import Combine
import UserNotifications

/// Local reminders for scheduled meds: one household notification per slot
/// (7am, 7pm) whenever any animal has something due in it, plus one per
/// long-term med on the day it falls due (9am), nagging daily once it's
/// late. No server — the schedule lives on the phone and is rebuilt from
/// the store each time the set of scheduled items or next-due days changes.
final class DoseReminders: NSObject, ObservableObject {
    static let shared = DoseReminders()

    enum Authorization: Equatable {
        case unknown
        case notAsked
        case granted
        case denied
    }

    @Published private(set) var authorization: Authorization = .unknown

    private weak var store: AppStore?
    private var subscription: AnyCancellable?
    private let center = UNUserNotificationCenter.current()

    static let categoryID = "DOSE_SLOT"
    static let givenActionID = "DOSE_GIVEN"
    static let snoozeActionID = "DOSE_SNOOZE"
    private static let slotKey = "slot"
    private static let petKey = "pet"
    private static let itemKey = "item"
    /// Long-term doses remind at a civil hour rather than the 7am slot.
    static let intervalHour = 9

    private override init() {
        super.init()
    }

    /// Call once at launch. Registers the notification actions, follows the
    /// store so the schedule tracks the regimen, and syncs immediately.
    func attach(store: AppStore) {
        self.store = store
        center.delegate = self

        let given = UNNotificationAction(identifier: Self.givenActionID, title: "Given ✓", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeActionID, title: "Remind me in an hour", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [given, snooze],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])

        subscription = store.$data
            .map(Self.scheduleSignature)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { await self?.resync() }
            }
        Task {
            await refreshAuthorization()
            await resync()
        }
    }

    /// Which (pet, slot) pairs currently need a reminder, and which (pet,
    /// long-term med) pairs are due on which day. Only a change here rebuilds
    /// the pending notifications; ticking a daily dose off doesn't, logging
    /// a monthly one does (its next-due day moved).
    private static func scheduleSignature(_ data: AppData) -> Set<String> {
        var signature = Set<String>()
        guard !data.isDemo else { return signature }
        for pet in data.pets where !pet.isArchived {
            for item in data.items where item.kind.isRegimen && item.applies(to: pet.id) {
                if item.isScheduled {
                    for slot in item.schedule {
                        signature.insert("\(pet.id.uuidString)|\(slot.rawValue)")
                    }
                }
                if item.isRecurring,
                   let state = intervalDoseState(item: item, intakes: data.intakes.filter { $0.petID == pet.id }) {
                    signature.insert("\(pet.id.uuidString)|\(item.id.uuidString)|\(state.nextDue.timeIntervalSince1970)|\(state.isCourseComplete)")
                }
            }
        }
        return signature
    }

    @MainActor
    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notAsked
        case .denied: authorization = .denied
        case .authorized, .provisional, .ephemeral: authorization = .granted
        @unknown default: authorization = .unknown
        }
    }

    /// Ask the first time something gets scheduled — that's the moment the
    /// permission makes sense to the person being asked.
    @discardableResult
    @MainActor
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        if granted { await resync() }
        return granted
    }

    /// Rebuild the pending dose reminders from the store: the two daily slot
    /// notifications, and one per (animal, long-term med) for its next due
    /// day.
    @MainActor
    func resync() async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard let store, !store.data.isDemo else { return }
        for slot in DoseSlot.allCases {
            let pets = store.activePets.filter { !store.scheduledItems(for: $0.id, slot: slot).isEmpty }
            guard !pets.isEmpty else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(slot.label) meds"
            content.body = Self.body(for: pets.map(\.name), slot: slot)
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.slotKey: slot.rawValue]
            var components = DateComponents()
            components.hour = slot.hour
            components.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: identifier(for: slot), content: content, trigger: trigger)
            try? await center.add(request)
        }
        for pet in store.activePets {
            for due in store.intervalDues(for: pet.id) where !due.state.isCourseComplete {
                try? await center.add(intervalRequest(pet: pet, due: due))
            }
        }
    }

    /// Fires at 9am on the due day. Once that has passed with nothing logged
    /// it repeats every morning until a dose goes in, at which point the
    /// signature changes and the resync replaces it with next month's.
    private func intervalRequest(pet: Pet, due: AppStore.IntervalDue) -> UNNotificationRequest {
        let calendar = Calendar.current
        let content = UNMutableNotificationContent()
        content.title = "\(pet.name)'s \(due.item.name)"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.petKey: pet.id.uuidString, Self.itemKey: due.item.id.uuidString]
        let fireAt = calendar.date(bySettingHour: Self.intervalHour, minute: 0, second: 0, of: due.state.nextDue) ?? due.state.nextDue
        let trigger: UNCalendarNotificationTrigger
        if fireAt > Date() {
            let dose = due.item.dose.isEmpty ? "" : " (\(due.item.dose))"
            content.body = "Due today\(dose) — \(due.item.cadenceLabel.lowercased()). Tap Given when it's done."
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            content.body = "Was due \(shortDate(due.state.nextDue)) and nothing's logged. Tap Given once it's done."
            var components = DateComponents()
            components.hour = Self.intervalHour
            components.minute = 0
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        }
        return UNNotificationRequest(identifier: identifier(petID: pet.id, itemID: due.item.id), content: content, trigger: trigger)
    }

    private static let idPrefix = "dose-"

    private func identifier(for slot: DoseSlot) -> String { Self.idPrefix + slot.rawValue }

    private func identifier(petID: UUID, itemID: UUID) -> String {
        Self.idPrefix + "interval-\(petID.uuidString)-\(itemID.uuidString)"
    }

    private static func body(for names: [String], slot: DoseSlot) -> String {
        let who: String
        switch names.count {
        case 0: who = "everyone"
        case 1: who = names[0]
        case 2: who = "\(names[0]) and \(names[1])"
        default: who = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
        return "Time for \(who)'s \(slot.label.lowercased()) dose. Tap Given when it's done, or open Scoop to tick things off one by one."
    }

    /// One-shot follow-up an hour out, same content and actions.
    private func snooze(_ notification: UNNotification) async {
        let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent
            ?? UNMutableNotificationContent()
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        let request = UNNotificationRequest(identifier: notification.request.identifier + "-snooze", content: content, trigger: trigger)
        try? await center.add(request)
    }
}

extension DoseReminders: UNUserNotificationCenterDelegate {
    /// Show the banner even with Scoop in the foreground — the point is to
    /// be asked, not to find it later in the list.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case Self.givenActionID:
            await MainActor.run {
                guard let store else { return }
                if let raw = userInfo[Self.slotKey] as? String, let slot = DoseSlot(rawValue: raw) {
                    for pet in store.activePets {
                        store.giveSlot(petID: pet.id, slot: slot)
                    }
                } else if let petRaw = userInfo[Self.petKey] as? String, let petID = UUID(uuidString: petRaw),
                          let itemRaw = userInfo[Self.itemKey] as? String, let itemID = UUID(uuidString: itemRaw),
                          let item = store.item(itemID), item.isRecurring {
                    store.setIntervalDose(petID: petID, item: item, status: .given)
                }
            }
        case Self.snoozeActionID:
            await snooze(response.notification)
        default:
            break // plain tap: the app opens, the checklist is on the home screen
        }
    }
}
