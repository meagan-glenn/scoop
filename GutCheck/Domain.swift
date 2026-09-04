import Foundation

// MARK: - Core enums

enum Species: String, Codable, CaseIterable {
    case dog = "Dog"
    case cat = "Cat"
}

enum PetMode: String, Codable {
    case baseline
    case watch

    var label: String {
        switch self {
        case .baseline: return "Baseline"
        case .watch: return "Watch"
        }
    }
}

/// Four-tier triage ladder (W11). Ordered by severity.
enum Tier: Int, Codable, Comparable, CaseIterable {
    case normal = 0
    case monitor = 1
    case concern = 2
    case urgent = 3

    static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .monitor: return "Monitor"
        case .concern: return "Concern"
        case .urgent: return "Urgent"
        }
    }
}

// MARK: - The 4Cs

/// C1 — Consistency. Owner-facing five-point scale over a stored 1–7 vet value.
/// `hard` is real but demoted behind a "more" control in the UI.
enum ConsistencyChoice: String, Codable, CaseIterable, Identifiable {
    case logs
    case littleSoft
    case softServe
    case diarrhea
    case liquid
    case hard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .logs: return "Logs"
        case .littleSoft: return "A little soft"
        case .softServe: return "Soft serve"
        case .diarrhea: return "Diarrhea"
        case .liquid: return "Liquid"
        case .hard: return "Hard"
        }
    }

    /// Stored veterinary 1–7 value underneath the owner label.
    var vetScore: Int {
        switch self {
        case .hard: return 1
        case .logs: return 2
        case .littleSoft: return 4
        case .softServe: return 5
        case .diarrhea: return 6
        case .liquid: return 7
        }
    }

    /// Base tier before the liquid-frequency escalation rule.
    var tier: Tier {
        switch self {
        case .logs: return .normal
        case .littleSoft, .softServe, .hard: return .monitor
        case .diarrhea: return .concern
        case .liquid: return .concern // escalates to .urgent at 3+ in 24h
        }
    }

    /// Primary chips shown up front; `hard` lives behind "more".
    static var primary: [ConsistencyChoice] { [.logs, .littleSoft, .softServe, .diarrhea, .liquid] }
}

/// C2 — Color.
enum StoolColor: String, Codable, CaseIterable, Identifiable {
    case brown
    case green
    case yellowOrange
    case greyGreasy
    case redStreaks
    case whiteChalky
    case blackTarry
    case pinkPurple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brown: return "Brown"
        case .green: return "Green"
        case .yellowOrange: return "Yellow / orange"
        case .greyGreasy: return "Grey / greasy"
        case .redStreaks: return "Red streaks"
        case .whiteChalky: return "White / chalky"
        case .blackTarry: return "Black / tarry"
        case .pinkPurple: return "Pink / purple"
        }
    }

    var tier: Tier {
        switch self {
        case .brown: return .normal
        case .green, .whiteChalky: return .monitor
        case .yellowOrange, .greyGreasy, .redStreaks: return .concern
        case .blackTarry, .pinkPurple: return .urgent
        }
    }

    /// Common values one tap away; rare ones behind "more".
    static var primary: [StoolColor] { [.brown, .green, .yellowOrange, .redStreaks] }
    static var secondary: [StoolColor] { [.greyGreasy, .whiteChalky, .blackTarry, .pinkPurple] }
}

/// C3 — Coating.
enum Coating: String, Codable, CaseIterable, Identifiable {
    case none
    case mucus
    case greasy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .mucus: return "Mucus / jelly"
        case .greasy: return "Greasy sheen"
        }
    }

    var tier: Tier {
        switch self {
        case .none: return .normal
        case .mucus, .greasy: return .concern
        }
    }
}

/// C4 — Contents.
enum Contents: String, Codable, CaseIterable, Identifiable {
    case none
    case riceSpecks
    case grass
    case hair
    case foreignMaterial
    case blood

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .riceSpecks: return "Rice-like specks"
        case .grass: return "Grass"
        case .hair: return "Hair"
        case .foreignMaterial: return "Foreign material"
        case .blood: return "Visible blood"
        }
    }

    var tier: Tier {
        switch self {
        case .none: return .normal
        case .riceSpecks, .grass, .hair: return .monitor
        case .foreignMaterial, .blood: return .concern
        }
    }
}

/// One captured stool observation across all four axes.
struct StoolReading: Codable, Equatable {
    var consistency: ConsistencyChoice
    var color: StoolColor
    var coating: Coating
    var contents: Contents

    static var normal: StoolReading {
        StoolReading(consistency: .logs, color: .brown, coating: .none, contents: .none)
    }
}

/// When did this actually happen? Real logging is often retroactive, and every
/// causal window (24h liquid rule, 48h lookback, 72h attribution) depends on
/// honest timestamps.
enum LogTiming: String, CaseIterable, Identifiable {
    case justNow
    case earlierToday
    case yesterday

    var id: String { rawValue }

    var label: String {
        switch self {
        case .justNow: return "Just now"
        case .earlierToday: return "Earlier today"
        case .yesterday: return "Yesterday"
        }
    }

    /// Whether the user should be offered a clock-time picker for this choice.
    var needsTime: Bool { self != .justNow }

    /// Sensible starting point for the time picker when this option is chosen.
    var defaultDate: Date {
        let now = Date()
        switch self {
        case .justNow:
            return now
        case .earlierToday:
            // ~6h back, clamped so it never crosses midnight.
            let floor = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
            return max(floor, now.addingTimeInterval(-6 * 3600))
        case .yesterday:
            return now.addingTimeInterval(-24 * 3600)
        }
    }

    /// Valid picker range: the chosen day, never in the future.
    var range: ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        switch self {
        case .justNow:
            return now...now
        case .earlierToday:
            return today...now
        case .yesterday:
            let yStart = cal.date(byAdding: .day, value: -1, to: today) ?? today
            return yStart...today.addingTimeInterval(-60)
        }
    }

    /// Final timestamp: the chosen day combined with the picked clock time.
    func resolve(pickedTime: Date) -> Date {
        switch self {
        case .justNow:
            return Date()
        case .earlierToday, .yesterday:
            let cal = Calendar.current
            let day = cal.startOfDay(for: range.lowerBound)
            let hm = cal.dateComponents([.hour, .minute], from: pickedTime)
            let combined = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? day
            return min(max(combined, range.lowerBound), range.upperBound)
        }
    }
}

/// Triage across all four axes, with the liquid-frequency escalation
/// (score 7 three or more times in 24h → urgent).
func triageTier(for reading: StoolReading, liquidCountLast24h: Int) -> Tier {
    var tier = max(reading.consistency.tier,
                   max(reading.color.tier,
                       max(reading.coating.tier, reading.contents.tier)))
    if reading.consistency == .liquid && liquidCountLast24h >= 3 {
        tier = .urgent
    }
    return tier
}

// MARK: - Interventions & protocols

enum InterventionKind: String, Codable, CaseIterable, Identifiable {
    case fasted
    case blandDiet
    case pumpkin
    case probiotic
    case removedItem
    case startedMed
    case calledVet
    case vetVisit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fasted: return "Fasted"
        case .blandDiet: return "Bland diet"
        case .pumpkin: return "Pumpkin / fiber"
        case .probiotic: return "Probiotic"
        case .removedItem: return "Removed an item"
        case .startedMed: return "Started a med"
        case .calledVet: return "Called the vet"
        case .vetVisit: return "Vet visit"
        }
    }

    var symbol: String {
        switch self {
        case .fasted: return "clock"
        case .blandDiet: return "fork.knife"
        case .pumpkin: return "leaf"
        case .probiotic: return "pills"
        case .removedItem: return "minus.circle"
        case .startedMed: return "cross.vial"
        case .calledVet: return "phone"
        case .vetVisit: return "stethoscope"
        }
    }
}

// MARK: - Exposures

/// A cause-side input known at the moment it happens — meds and stress, plus
/// intake deviations. Sibling of cross-feeding: logged in the moment, surfaced
/// by the lookback, correlated by the insight engine.
enum ExposureKind: String, Codable, CaseIterable, Identifiable {
    case medStarted
    case medChanged
    case travelBoarding
    case houseGuests
    case stressfulEvent
    case foundOutside
    case tableFood
    case newChew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .medStarted: return "Started a med"
        case .medChanged: return "Med change"
        case .travelBoarding: return "Travel / boarding"
        case .houseGuests: return "House guests"
        case .stressfulEvent: return "Stressful event"
        case .foundOutside: return "Found something outside"
        case .tableFood: return "Table food"
        case .newChew: return "New chew"
        }
    }

    var symbol: String {
        switch self {
        case .medStarted, .medChanged: return "pills.fill"
        case .travelBoarding: return "suitcase.fill"
        case .houseGuests: return "person.2.fill"
        case .stressfulEvent: return "cloud.bolt.fill"
        case .foundOutside: return "leaf.fill"
        case .tableFood: return "fork.knife"
        case .newChew: return "circle.grid.cross.fill"
        }
    }

    var isMedication: Bool {
        self == .medStarted || self == .medChanged
    }

    /// Stress-type exposures usually hit the whole household; meds hit one animal.
    var defaultsToHousehold: Bool {
        switch self {
        case .travelBoarding, .houseGuests, .stressfulEvent: return true
        default: return false
        }
    }
}

struct ExposureEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var petID: UUID? // nil = the whole household
    var kind: ExposureKind
    var note: String
    var date: Date

    init(id: UUID = UUID(), petID: UUID?, kind: ExposureKind, note: String = "", date: Date) {
        self.id = id
        self.petID = petID
        self.kind = kind
        self.note = note
        self.date = date
    }

    func applies(to pet: UUID) -> Bool {
        petID == nil || petID == pet
    }
}

// MARK: - Records

struct Pet: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var species: Species
    var breed: String
    var avatar: String // emoji avatar (avatars only — never on the clinical scale)
    var conditions: [String]
    var mode: PetMode
    var photoFilename: String? // profile photo in Documents/photos; emoji fallback when nil
    var birthdate: Date?
    var isArchived: Bool // out of the household, history kept

    init(id: UUID = UUID(), name: String, species: Species, breed: String, avatar: String,
         conditions: [String] = [], mode: PetMode = .baseline, photoFilename: String? = nil,
         birthdate: Date? = nil, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.species = species
        self.breed = breed
        self.avatar = avatar
        self.conditions = conditions
        self.mode = mode
        self.photoFilename = photoFilename
        self.birthdate = birthdate
        self.isArchived = isArchived
    }

    // Tolerant decoding: fields added after launch must not wipe stored pets.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        species = try container.decode(Species.self, forKey: .species)
        breed = try container.decode(String.self, forKey: .breed)
        avatar = try container.decode(String.self, forKey: .avatar)
        conditions = try container.decodeIfPresent([String].self, forKey: .conditions) ?? []
        mode = try container.decodeIfPresent(PetMode.self, forKey: .mode) ?? .baseline
        photoFilename = try container.decodeIfPresent(String.self, forKey: .photoFilename)
        birthdate = try container.decodeIfPresent(Date.self, forKey: .birthdate)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    /// "8 mo" / "4 yrs" — age is what the vet actually asks for.
    var ageLabel: String? {
        guard let birthdate else { return nil }
        let months = max(0, Calendar.current.dateComponents([.month], from: birthdate, to: Date()).month ?? 0)
        if months < 12 { return "\(months) mo" }
        let years = months / 12
        return "\(years) yr\(years == 1 ? "" : "s")"
    }
}

enum ItemScope: Codable, Equatable {
    case household
    case pet(UUID)
}

/// What an item is. Meals, meds and supplements are per-animal; treats and
/// chews are usually handed out house-wide (PRD: "treats are chaos").
enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case med
    case supplement
    case food
    case treat
    case chew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .med: return "Medication"
        case .supplement: return "Supplement"
        case .food: return "Food"
        case .treat: return "Treat / table food"
        case .chew: return "Chew"
        }
    }

    var symbol: String {
        switch self {
        case .med: return "pills.fill"
        case .supplement: return "leaf.fill"
        case .food: return "bowl.fill"
        case .treat: return "fork.knife"
        case .chew: return "circle.grid.cross.fill"
        }
    }

    /// Meds and supplements are a regimen: they can be scheduled and their
    /// adherence matters. Food, treats and chews are one-off intake.
    var isRegimen: Bool { self == .med || self == .supplement }

    /// Household by default for the chaotic categories; per-pet otherwise.
    var defaultsToHousehold: Bool { self == .treat || self == .chew }
}

/// The two daily dosing slots. Reminders fire at `hour` local time.
enum DoseSlot: String, Codable, CaseIterable, Identifiable {
    case morning
    case evening

    var id: String { rawValue }

    var label: String {
        switch self {
        case .morning: return "Morning"
        case .evening: return "Evening"
        }
    }

    var symbol: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .evening: return "moon.stars.fill"
        }
    }

    /// Reminder hour, 24h local time.
    var hour: Int {
        switch self {
        case .morning: return 7
        case .evening: return 19
        }
    }

    /// The slot's due time on a given calendar day.
    func dueDate(on day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start) ?? start
    }

    /// Which slot "now" most naturally belongs to — used to pre-select a slot
    /// when logging a scheduled dose without a checklist tap.
    static func current(at date: Date = Date(), calendar: Calendar = .current) -> DoseSlot {
        calendar.component(.hour, from: date) < 14 ? .morning : .evening
    }
}

/// How often a long-term med recurs when it isn't a daily slot: a monthly
/// heartworm chew, a monthly joint injection, a flea treatment every three
/// months. The next dose is derived from the last one given, never stored,
/// so a late dose simply moves the whole schedule rather than piling up.
struct DoseInterval: Codable, Equatable, Hashable {
    enum Unit: String, Codable, CaseIterable, Identifiable {
        case day
        case week
        case month

        var id: String { rawValue }

        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            }
        }

        /// "day" / "days"
        func label(_ count: Int) -> String {
            rawValue + (count == 1 ? "" : "s")
        }
    }

    var count: Int
    var unit: Unit

    init(count: Int, unit: Unit) {
        self.count = max(1, count)
        self.unit = unit
    }

    static let weekly = DoseInterval(count: 1, unit: .week)
    static let everyTwoWeeks = DoseInterval(count: 2, unit: .week)
    static let monthly = DoseInterval(count: 1, unit: .month)
    static let everyThreeMonths = DoseInterval(count: 3, unit: .month)

    /// The common cadences, one tap away. Anything else is a count and a unit.
    static let presets: [DoseInterval] = [.weekly, .everyTwoWeeks, .monthly, .everyThreeMonths]

    /// "Every month", "Every 2 weeks", "Every other day".
    var label: String {
        if count == 2, unit == .day { return "Every other day" }
        if count == 1 {
            switch unit {
            case .day: return "Every day"
            case .week: return "Every week"
            case .month: return "Every month"
            }
        }
        return "Every \(count) \(unit.label(count))"
    }

    /// "Monthly dose", "Weekly dose", "Dose every 3 months" — for a timeline row.
    var doseLabel: String {
        if count == 1 {
            switch unit {
            case .day: return "Daily dose"
            case .week: return "Weekly dose"
            case .month: return "Monthly dose"
            }
        }
        return "Dose every \(count) \(unit.label(count))"
    }

    /// When the next dose falls, counting from the last one.
    func next(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: unit.component, value: count, to: date) ?? date.addingTimeInterval(Double(count) * 30 * 24 * 3600)
    }
}

/// A named thing the animal gets: a med, a supplement, a food, a treat. Named
/// so that the third time banana shows up before an episode, the app can say
/// so — a free-text note never becomes a pattern.
struct Item: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var scope: ItemScope
    var kind: ItemKind
    /// When it entered the animal's life (a course start, a new bag of food).
    var firstIntroduced: Date
    /// Default amount per dose — "250mg", "1 tsp", "a few bites".
    var dose: String
    /// Daily slots this is due in. Empty = as needed / one-off, unless an
    /// `interval` makes it a long-term recurring dose.
    var schedule: [DoseSlot]
    /// Long-term cadence (monthly heartworm, a monthly injection). Mutually
    /// exclusive with `schedule`: a med is daily or it recurs, not both.
    var interval: DoseInterval?
    /// A course with a planned end — "weekly for 6 weeks", "twice a day for
    /// 10 days" — measured from `firstIntroduced`. Nil = ongoing.
    var courseLength: DoseInterval?
    /// Adherence is only counted from here: backdating "started two weeks
    /// ago" must not invent two weeks of missed doses.
    var trackedSince: Date
    /// Set when a course ends. Kept, not deleted — history matters.
    var stopped: Date?

    init(id: UUID = UUID(), name: String, scope: ItemScope, kind: ItemKind, firstIntroduced: Date,
         dose: String = "", schedule: [DoseSlot] = [], interval: DoseInterval? = nil,
         courseLength: DoseInterval? = nil, trackedSince: Date? = nil, stopped: Date? = nil) {
        self.id = id
        self.name = name
        self.scope = scope
        self.kind = kind
        self.firstIntroduced = firstIntroduced
        self.dose = dose
        self.schedule = interval == nil ? schedule : []
        self.interval = interval
        self.courseLength = courseLength
        self.trackedSince = trackedSince ?? firstIntroduced
        self.stopped = stopped
    }

    // Tolerant decoding: `kind` was a free string before it became an enum,
    // and every field after it was added later.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scope = try container.decodeIfPresent(ItemScope.self, forKey: .scope) ?? .household
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        kind = ItemKind(rawValue: rawKind) ?? .treat
        firstIntroduced = try container.decodeIfPresent(Date.self, forKey: .firstIntroduced) ?? Date()
        dose = try container.decodeIfPresent(String.self, forKey: .dose) ?? ""
        schedule = try container.decodeIfPresent([DoseSlot].self, forKey: .schedule) ?? []
        interval = try container.decodeIfPresent(DoseInterval.self, forKey: .interval)
        courseLength = try container.decodeIfPresent(DoseInterval.self, forKey: .courseLength)
        trackedSince = try container.decodeIfPresent(Date.self, forKey: .trackedSince) ?? firstIntroduced
        stopped = try container.decodeIfPresent(Date.self, forKey: .stopped)
    }

    var isActive: Bool { stopped == nil }
    /// On a daily slot schedule (checklist, 7am/7pm reminders). A course
    /// that has run its planned length drops off the checklist by itself.
    var isScheduled: Bool { isActive && !schedule.isEmpty && !courseEnded }
    /// On a long-term cadence (next dose derived from the last).
    var isRecurring: Bool { isActive && interval != nil }

    /// Last day of a fixed-length course, or nil when ongoing. "For 6 weeks"
    /// from a Monday ends the Sunday six weeks on, so a weekly dose lands
    /// six times, not seven.
    func plannedEnd(calendar: Calendar = .current) -> Date? {
        courseLength.map { Self.courseEnd(start: firstIntroduced, length: $0, calendar: calendar) }
    }

    /// Last day of a course of `length` starting on `start`.
    static func courseEnd(start: Date, length: DoseInterval, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: start)
        let end = length.next(after: day, calendar: calendar)
        return calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    /// The planned course is over (today is past its last day).
    var courseEnded: Bool {
        hasCourseEnded(on: Date())
    }

    func hasCourseEnded(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let end = plannedEnd(calendar: calendar) else { return false }
        return calendar.startOfDay(for: date) > end
    }

    /// How many recurring doses the course calls for: every due date from the
    /// start through the planned end. Nil when ongoing or not recurring.
    func plannedDoseCount(calendar: Calendar = .current) -> Int? {
        guard let interval, let end = plannedEnd(calendar: calendar) else { return nil }
        var count = 0
        var due = calendar.startOfDay(for: firstIntroduced)
        while due <= end, count < 1000 {
            count += 1
            due = interval.next(after: due, calendar: calendar)
        }
        return count
    }

    /// "for 6 weeks" — nil when ongoing.
    var courseLabel: String? {
        courseLength.map { "for \($0.count) \($0.unit.label($0.count))" }
    }

    /// "Morning & Evening" / "Every month" / "As needed".
    var cadenceLabel: String {
        if let interval { return interval.label }
        if schedule.isEmpty { return "As needed" }
        return schedule.map(\.label).joined(separator: " & ")
    }

    func applies(to pet: UUID) -> Bool {
        switch scope {
        case .household: return true
        case .pet(let owner): return owner == pet
        }
    }

    /// Whether a scheduled dose was expected on this day.
    func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
        guard !schedule.isEmpty else { return false }
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)
        guard trackedSince < dayEnd else { return false }
        if let stopped, stopped < dayStart { return false }
        if let end = plannedEnd(calendar: calendar), dayStart > end { return false }
        return true
    }
}

enum IntakeStatus: String, Codable {
    case given
    /// Deliberately not given (vet said pause, animal wouldn't take it).
    /// Recorded so the checklist stops asking and the record stays honest.
    case skipped
}

/// "Albus got X." The record behind the checklist tick, the banana log, and
/// every adherence and attribution count.
struct IntakeEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var petID: UUID
    var itemID: UUID
    var date: Date
    var amount: String
    /// The scheduled slot this satisfies; nil for an ad-hoc dose or a treat.
    var slot: DoseSlot?
    var status: IntakeStatus
    var note: String

    init(id: UUID = UUID(), petID: UUID, itemID: UUID, date: Date, amount: String = "",
         slot: DoseSlot? = nil, status: IntakeStatus = .given, note: String = "") {
        self.id = id
        self.petID = petID
        self.itemID = itemID
        self.date = date
        self.amount = amount
        self.slot = slot
        self.status = status
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        petID = try container.decode(UUID.self, forKey: .petID)
        itemID = try container.decode(UUID.self, forKey: .itemID)
        date = try container.decode(Date.self, forKey: .date)
        amount = try container.decodeIfPresent(String.self, forKey: .amount) ?? ""
        slot = try container.decodeIfPresent(DoseSlot.self, forKey: .slot)
        status = try container.decodeIfPresent(IntakeStatus.self, forKey: .status) ?? .given
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// State of one scheduled slot on one day, derived rather than stored so a
/// missed dose needs no background job to be recorded.
enum DoseState: Equatable {
    case given(IntakeEvent)
    case skipped(IntakeEvent)
    /// Slot time has passed today and nothing is logged.
    case due
    /// The day ended with nothing logged.
    case missed
    /// Slot time hasn't arrived yet today.
    case upcoming

    var isLogged: Bool {
        switch self {
        case .given, .skipped: return true
        default: return false
        }
    }
}

/// Pure slot-state rule, shared by the checklist, the lookback and the summary.
func doseState(intakes: [IntakeEvent], slot: DoseSlot, day: Date, now: Date = Date(),
               calendar: Calendar = .current) -> DoseState {
    let dayStart = calendar.startOfDay(for: day)
    let dayEnd = dayStart.addingTimeInterval(24 * 3600)
    let logged = intakes
        .filter { $0.slot == slot && $0.date >= dayStart && $0.date < dayEnd }
        .sorted { $0.date > $1.date }
    if let latest = logged.first {
        return latest.status == .given ? .given(latest) : .skipped(latest)
    }
    if now >= dayEnd { return .missed }
    return now >= slot.dueDate(on: day, calendar: calendar) ? .due : .upcoming
}

/// Where a long-term recurring dose stands, derived from the last one logged
/// so nothing has to run in the background to notice a monthly chew is late.
struct IntervalDoseState: Equatable {
    /// The most recent dose logged, given or deliberately skipped. A skip
    /// still anchors the next due date — the vet said "not this month", not
    /// "never again".
    var last: IntakeEvent?
    /// Start of the day the next dose falls on.
    var nextDue: Date
    /// Whole days from today to `nextDue`; zero = due today, negative = late.
    var daysUntilDue: Int
    /// A dose logged today. Lets the home screen undo a mis-tap in place.
    var givenToday: IntakeEvent?
    /// Doses given so far, all time — "dose 3 of 6".
    var dosesGiven: Int
    /// Doses the course calls for; nil when ongoing.
    var plannedDoses: Int?
    /// The course has run past its last day, logged or not.
    var courseEnded: Bool

    /// Every planned dose is in, or the course's time is up. Nothing more
    /// is due; the item is waiting to be marked stopped.
    var isCourseComplete: Bool {
        if courseEnded { return true }
        if let plannedDoses { return dosesGiven >= plannedDoses }
        return false
    }

    var isDue: Bool { daysUntilDue <= 0 && !isCourseComplete }
    var isOverdue: Bool { daysUntilDue < 0 && !isCourseComplete }
    var isLogged: Bool { givenToday != nil }

    /// "dose 3 of 6" for the one coming up (or given today); "6 of 6 given"
    /// once the course is done. Nil when ongoing.
    var progressLabel: String? {
        guard let plannedDoses else { return nil }
        if isCourseComplete { return "\(dosesGiven) of \(plannedDoses) given" }
        return "dose \(min(dosesGiven + (isLogged ? 0 : 1), plannedDoses)) of \(plannedDoses)"
    }

    /// "Due today" / "Due in 12 days" / "3 days overdue" / "Course complete".
    var dueLabel: String {
        if isCourseComplete { return "Course complete" }
        if daysUntilDue == 0 { return "Due today" }
        if daysUntilDue == 1 { return "Due tomorrow" }
        if daysUntilDue > 0 { return "Due in \(daysUntilDue) days" }
        let late = -daysUntilDue
        return "\(late) day\(late == 1 ? "" : "s") overdue"
    }
}

/// Pure interval rule, shared by the checklist, the reminders and the summary.
/// `intakes` should already be scoped to the animal; the item filter is a
/// belt-and-braces. With no dose logged yet the first one is due the day
/// tracking began (the start date, or the day a cadence was added to an
/// existing item), so "nothing logged" reads as due rather than silently
/// fine — and never as months overdue for a med that was simply untracked.
func intervalDoseState(item: Item, intakes: [IntakeEvent], now: Date = Date(),
                       calendar: Calendar = .current) -> IntervalDoseState? {
    guard let interval = item.interval else { return nil }
    let logged = intakes
        .filter { $0.itemID == item.id }
        .sorted { $0.date > $1.date }
    let last = logged.first
    let nextDue = last.map { interval.next(after: $0.date, calendar: calendar) } ?? max(item.firstIntroduced, item.trackedSince)
    let dueDay = calendar.startOfDay(for: nextDue)
    let today = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
    let givenToday = logged.first { $0.status == .given && calendar.isDate($0.date, inSameDayAs: now) }
    let given = logged.filter { $0.status == .given }.count
    return IntervalDoseState(last: last, nextDue: dueDay, daysUntilDue: days, givenToday: givenToday,
                             dosesGiven: given, plannedDoses: item.plannedDoseCount(calendar: calendar),
                             courseEnded: item.hasCourseEnded(on: now, calendar: calendar))
}

struct OutputEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var petID: UUID
    var date: Date
    var reading: StoolReading
    var tier: Tier // computed at log time, with 24h context
    var note: String
    var photoFilename: String? // stored in Documents; nil when no photo attached

    init(id: UUID = UUID(), petID: UUID, date: Date, reading: StoolReading, tier: Tier, note: String = "", photoFilename: String? = nil) {
        self.id = id
        self.petID = petID
        self.date = date
        self.reading = reading
        self.tier = tier
        self.note = note
        self.photoFilename = photoFilename
    }
}

struct Intervention: Identifiable, Codable, Equatable {
    var id: UUID
    var petID: UUID
    var episodeID: UUID?
    var kind: InterventionKind
    var date: Date

    init(id: UUID = UUID(), petID: UUID, episodeID: UUID?, kind: InterventionKind, date: Date) {
        self.id = id
        self.petID = petID
        self.episodeID = episodeID
        self.kind = kind
        self.date = date
    }
}

struct CrossFeed: Identifiable, Codable, Equatable {
    var id: UUID
    var eaterID: UUID
    var foodOwnerID: UUID
    var amount: String // "a few bites", "the whole bowl"
    var date: Date

    init(id: UUID = UUID(), eaterID: UUID, foodOwnerID: UUID, amount: String, date: Date) {
        self.id = id
        self.eaterID = eaterID
        self.foodOwnerID = foodOwnerID
        self.amount = amount
        self.date = date
    }
}

struct Episode: Identifiable, Codable, Equatable {
    var id: UUID
    var petID: UUID
    var start: Date
    var end: Date?
    var note: String // "what's wrong"

    var isActive: Bool { end == nil }

    var durationDays: Int {
        let endDate = end ?? Date()
        return max(1, Calendar.current.dateComponents([.day], from: start, to: endDate).day.map { $0 + 1 } ?? 1)
    }

    init(id: UUID = UUID(), petID: UUID, start: Date, end: Date? = nil, note: String) {
        self.id = id
        self.petID = petID
        self.start = start
        self.end = end
        self.note = note
    }
}

/// Number of trailing consecutive normal-tier outputs — resolution fires at 3.
func consecutiveNormals(events: [OutputEvent]) -> Int {
    let sorted = events.sorted { $0.date < $1.date }
    var count = 0
    for event in sorted.reversed() {
        if event.tier == .normal {
            count += 1
        } else {
            break
        }
    }
    return count
}
