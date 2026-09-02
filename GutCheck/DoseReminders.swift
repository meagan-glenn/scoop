import Foundation
import Combine
import UserNotifications

/// Local reminders for scheduled meds: one household notification per slot
/// (7am, 7pm) whenever any animal has something due in it. No server — the
/// schedule lives on the phone and is rebuilt from the store each time the
/// set of scheduled items changes.
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

    /// Which (pet, slot) pairs currently need a reminder. Only a change here
    /// rebuilds the pending notifications; ticking a dose off doesn't.
    private static func scheduleSignature(_ data: AppData) -> Set<String> {
        var signature = Set<String>()
        guard !data.isDemo else { return signature }
        for pet in data.pets where !pet.isArchived {
            for item in data.items where item.isScheduled && item.kind.isRegimen && item.applies(to: pet.id) {
                for slot in item.schedule {
                    signature.insert("\(pet.id.uuidString)|\(slot.rawValue)")
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

    /// Rebuild the pending slot reminders from the store.
    @MainActor
    func resync() async {
        let slotIDs = DoseSlot.allCases.map(identifier)
        center.removePendingNotificationRequests(withIdentifiers: slotIDs)
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
    }

    private func identifier(for slot: DoseSlot) -> String { "dose-\(slot.rawValue)" }

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
    private func snooze(_ notification: UNNotification, slot: DoseSlot) async {
        let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent
            ?? UNMutableNotificationContent()
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(for: slot) + "-snooze", content: content, trigger: trigger)
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
        guard let raw = response.notification.request.content.userInfo[Self.slotKey] as? String,
              let slot = DoseSlot(rawValue: raw) else { return }
        switch response.actionIdentifier {
        case Self.givenActionID:
            await MainActor.run {
                guard let store else { return }
                for pet in store.activePets {
                    store.giveSlot(petID: pet.id, slot: slot)
                }
            }
        case Self.snoozeActionID:
            await snooze(response.notification, slot: slot)
        default:
            break // plain tap: the app opens, the checklist is on the home screen
        }
    }
}
