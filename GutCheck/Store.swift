import Foundation
import Combine

struct AppData: Codable, Equatable {
    var pets: [Pet] = []
    var items: [Item] = []
    var events: [OutputEvent] = []
    var interventions: [Intervention] = []
    var crossFeeds: [CrossFeed] = []
    var episodes: [Episode] = []
    var exposures: [ExposureEvent] = []
    var hasOnboarded: Bool = false
    /// True while this device is exploring the bundled demo household. Demo
    /// data is a local sandbox: it never uploads to CloudKit and a real
    /// household must never merge into it.
    var isDemo: Bool = false

    init() {}

    // Tolerant decoding so adding fields never wipes an existing on-device file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pets = try container.decodeIfPresent([Pet].self, forKey: .pets) ?? []
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        events = try container.decodeIfPresent([OutputEvent].self, forKey: .events) ?? []
        interventions = try container.decodeIfPresent([Intervention].self, forKey: .interventions) ?? []
        crossFeeds = try container.decodeIfPresent([CrossFeed].self, forKey: .crossFeeds) ?? []
        episodes = try container.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
        exposures = try container.decodeIfPresent([ExposureEvent].self, forKey: .exposures) ?? []
        // Files written before onboarding existed already have a household.
        hasOnboarded = try container.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? !pets.isEmpty
        isDemo = try container.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
    }
}

struct LogResult {
    var tier: Tier
    var suggestWatch: Bool
    var suggestResolution: Bool
}

final class AppStore: ObservableObject {
    /// Sync seam: every local mutation flows through here as (old, new) so the
    /// sync layer can diff it into per-record changes. Remote applies set
    /// `isApplyingRemote` so they persist locally without echoing back up.
    var onLocalChange: ((AppData, AppData) -> Void)?
    var isApplyingRemote = false

    @Published var data: AppData {
        didSet {
            save()
            if !isApplyingRemote {
                onLocalChange?(oldValue, data)
            }
        }
    }

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("gutcheck.json")
    }()

    init() {
        if let loaded = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppData.self, from: loaded) {
            data = decoded
        } else {
            data = AppData() // fresh install → onboarding
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL)
        }
    }

    func resetToSeed() {
        data = AppStore.seed()
    }

    /// Leaves the demo sandbox entirely: demo data is discarded and the app
    /// returns to onboarding. Nothing in the demo ever synced, so there is
    /// nothing to undo in the cloud.
    func exitDemo() {
        data = AppData()
    }

    // MARK: - Demo hygiene

    /// The seed animals, identifiable by their exact signature. Used to scrub
    /// demo animals that older builds accidentally synced into a real
    /// household via CloudKit.
    private static let seedPetSignatures: Set<String> = [
        "Navi|Dog|Cattle dog mix|🐕",
        "Albus|Dog|Golden retriever|🦮",
        "Arya|Dog|Border collie|🐶",
    ]

    /// Household-scoped seed items carry no pet ID, so they are matched the
    /// same way the seed pets are: by exact signature.
    private static let seedHouseholdItemSignatures: Set<String> = [
        "Bully sticks|chew",
        "Yak cheese chew|chew",
    ]

    private static func isSeedPet(_ pet: Pet) -> Bool {
        pet.photoFilename == nil &&
            seedPetSignatures.contains("\(pet.name)|\(pet.species.rawValue)|\(pet.breed)|\(pet.avatar)")
    }

    /// Older builds could upload the demo household to CloudKit and later
    /// merge it into a real one. Straightens that out:
    ///
    /// - A household that is nothing but the seed is the demo itself (loaded
    ///   on a build before the flag existed) — it gets re-flagged as the demo
    ///   sandbox rather than wiped out from under the user.
    /// - A real household with seed animals mixed in gets them removed, along
    ///   with every record that references them. The removal is a normal
    ///   local mutation, so when sync is live the deletions propagate and
    ///   scrub the cloud copy too.
    ///
    /// - A demo animal that was renamed into a real one (the obvious way to
    ///   "set up your own" on a build with no delete and no exit) keeps its
    ///   identity but loses the pretend history it came with; see
    ///   `scrubSeedHistory`.
    ///
    /// Returns true when the data is (or turned out to be) the demo sandbox,
    /// which the sync layer takes as its cue to stay down.
    @discardableResult
    func reconcileDemoData() -> Bool {
        guard !data.isDemo else { return true }
        let demoIDs = Set(data.pets.filter(Self.isSeedPet).map(\.id))
        if !demoIDs.isEmpty, demoIDs.count == data.pets.count {
            data.isDemo = true
            return true
        }
        var cleaned = data
        if !demoIDs.isEmpty {
            cleaned.pets.removeAll { demoIDs.contains($0.id) }
            cleaned.events.removeAll { demoIDs.contains($0.petID) }
            cleaned.interventions.removeAll { demoIDs.contains($0.petID) }
            cleaned.crossFeeds.removeAll { demoIDs.contains($0.eaterID) || demoIDs.contains($0.foodOwnerID) }
            cleaned.episodes.removeAll { demoIDs.contains($0.petID) }
            cleaned.exposures.removeAll { $0.petID.map(demoIDs.contains) ?? false }
            cleaned.items.removeAll { item in
                switch item.scope {
                case .pet(let owner): return demoIDs.contains(owner)
                case .household: return Self.seedHouseholdItemSignatures.contains("\(item.name)|\(item.kind)")
                }
            }
        }
        Self.scrubSeedHistory(from: &cleaned)
        if cleaned != data {
            data = cleaned
        }
        return false
    }

    /// The seed's episodes are recognizable by their exact notes, and every
    /// other seed record was stamped relative to the same `now`, so once an
    /// episode is known each of them sits at a fixed offset from it. That
    /// fingerprint is what gets removed; anything a person logged (a photo,
    /// a note, an off-pattern timestamp) survives.
    private static func scrubSeedHistory(from data: inout AppData) {
        let day = 24 * 3600.0
        let tolerance = 2.0
        // note → offset of `now` from the episode's start (seed: daysAgo(61), daysAgo(1.1))
        let seedEpisodes: [String: TimeInterval] = [
            "Soft stool after park weekend": 61 * day,
            "Soft serve since yesterday morning": 1.1 * day,
        ]
        let demoEpisodes = data.episodes.filter { seedEpisodes[$0.note] != nil }
        guard !demoEpisodes.isEmpty else { return }

        func near(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < tolerance }

        var episodeIDs = Set<UUID>()
        var affectedPets = Set<UUID>()
        for episode in demoEpisodes {
            let now = episode.start.addingTimeInterval(seedEpisodes[episode.note]!)
            func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }
            let petID = episode.petID
            episodeIDs.insert(episode.id)
            affectedPets.insert(petID)

            let seedEventDates = [61, 59, 58, 57.2, 1.1, 5.0 / 24].map(ago)
            data.events.removeAll { event in
                event.petID == petID && event.photoFilename == nil && event.note.isEmpty &&
                    seedEventDates.contains { near($0, event.date) }
            }
            data.exposures.removeAll { exposure in
                exposure.petID == petID && exposure.kind == .medStarted &&
                    exposure.note == "joint supplement" && near(exposure.date, ago(2.5))
            }
            data.crossFeeds.removeAll { feed in
                feed.eaterID == petID && feed.amount == "half the bowl" && near(feed.date, ago(2))
            }
            let seedItems: [(String, Double)] = [("Hill's i/d|food", 220), ("Puppy kibble|food", 90), ("Salmon kibble|food", 300)]
            data.items.removeAll { item in
                guard case .pet(let owner) = item.scope, owner == petID else { return false }
                return seedItems.contains { $0.0 == "\(item.name)|\(item.kind)" && near(item.firstIntroduced, ago($0.1)) }
            }
        }
        data.interventions.removeAll { $0.episodeID.map(episodeIDs.contains) ?? false }
        data.episodes.removeAll { episodeIDs.contains($0.id) }

        // The seed opened Navi in watch mode. Watch without an episode is
        // meaningless, so a pet left that way goes back to baseline.
        for index in data.pets.indices where affectedPets.contains(data.pets[index].id) {
            let stillActive = data.episodes.contains { $0.petID == data.pets[index].id && $0.isActive }
            if !stillActive, data.pets[index].mode == .watch {
                data.pets[index].mode = .baseline
            }
        }
    }

    // MARK: - Lookups

    func pet(_ id: UUID) -> Pet? {
        data.pets.first { $0.id == id }
    }

    /// The household as the user sees it — archived animals keep their history
    /// but leave every picker and list.
    var activePets: [Pet] {
        data.pets.filter { !$0.isArchived }
    }

    func lastOutputDate(for petID: UUID) -> Date? {
        data.events.filter { $0.petID == petID }.map(\.date).max()
    }

    func activeEpisode(for petID: UUID) -> Episode? {
        data.episodes.first { $0.petID == petID && $0.isActive }
    }

    func events(in episode: Episode) -> [OutputEvent] {
        data.events
            .filter { $0.petID == episode.petID && $0.date >= episode.start && (episode.end == nil || $0.date <= episode.end!) }
            .sorted { $0.date > $1.date }
    }

    func interventions(in episode: Episode) -> [Intervention] {
        data.interventions
            .filter { $0.episodeID == episode.id }
            .sorted { $0.date > $1.date }
    }

    func resolvedEpisodes(for petID: UUID) -> [Episode] {
        data.episodes
            .filter { $0.petID == petID && !$0.isActive }
            .sorted { $0.start > $1.start }
    }

    func resolutionProgress(for episode: Episode) -> Int {
        consecutiveNormals(events: events(in: episode).sorted { $0.date < $1.date })
    }

    // MARK: - Mutations

    // MARK: - Photos

    private var photosDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func savePhoto(_ imageData: Data) -> String {
        let filename = UUID().uuidString + ".jpg"
        try? imageData.write(to: photosDirectory.appendingPathComponent(filename))
        return filename
    }

    func photoURL(_ filename: String) -> URL {
        photosDirectory.appendingPathComponent(filename)
    }

    func logOutput(petID: UUID, reading: StoolReading, note: String, photoFilename: String? = nil, date: Date = Date()) -> LogResult {
        let dayAgo = date.addingTimeInterval(-24 * 3600)
        let liquidCount = data.events.filter {
            $0.petID == petID && $0.date >= dayAgo && $0.reading.consistency == .liquid
        }.count + (reading.consistency == .liquid ? 1 : 0)

        let tier = triageTier(for: reading, liquidCountLast24h: liquidCount)
        let event = OutputEvent(petID: petID, date: date, reading: reading, tier: tier, note: note, photoFilename: photoFilename)
        data.events.append(event)

        let active = activeEpisode(for: petID)
        let suggestWatch = tier > .normal && active == nil
        var suggestResolution = false
        if let episode = active, tier == .normal {
            suggestResolution = resolutionProgress(for: episode) >= 3
        }
        return LogResult(tier: tier, suggestWatch: suggestWatch, suggestResolution: suggestResolution)
    }

    @discardableResult
    func startEpisode(petID: UUID, note: String) -> Episode {
        let episode = Episode(petID: petID, start: Date(), note: note)
        data.episodes.append(episode)
        if let index = data.pets.firstIndex(where: { $0.id == petID }) {
            data.pets[index].mode = .watch
        }
        return episode
    }

    func resolveEpisode(_ episode: Episode) {
        guard let index = data.episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        data.episodes[index].end = Date()
        if let petIndex = data.pets.firstIndex(where: { $0.id == episode.petID }) {
            data.pets[petIndex].mode = .baseline
        }
    }

    func addIntervention(kind: InterventionKind, petID: UUID) {
        let episodeID = activeEpisode(for: petID)?.id
        data.interventions.append(Intervention(petID: petID, episodeID: episodeID, kind: kind, date: Date()))
    }

    func logCrossFeed(eaterID: UUID, foodOwnerID: UUID, amount: String) {
        data.crossFeeds.append(CrossFeed(eaterID: eaterID, foodOwnerID: foodOwnerID, amount: amount, date: Date()))
    }

    @discardableResult
    func logExposure(kind: ExposureKind, petID: UUID?, note: String = "", date: Date = Date()) -> ExposureEvent {
        let exposure = ExposureEvent(petID: petID, kind: kind, note: note, date: date)
        data.exposures.append(exposure)
        return exposure
    }

    func removeExposure(id: UUID) {
        data.exposures.removeAll { $0.id == id }
    }

    // MARK: - Corrections (the record can be wrong; make wrong fixable)

    func removeEvent(id: UUID) {
        if let event = data.events.first(where: { $0.id == id }),
           let filename = event.photoFilename {
            try? FileManager.default.removeItem(at: photoURL(filename))
        }
        data.events.removeAll { $0.id == id }
    }

    func removeIntervention(id: UUID) {
        data.interventions.removeAll { $0.id == id }
    }

    func removeCrossFeed(id: UUID) {
        data.crossFeeds.removeAll { $0.id == id }
    }

    /// Archive keeps every log and episode; the animal just leaves the household.
    func archivePet(_ id: UUID) {
        if let episode = activeEpisode(for: id) {
            resolveEpisode(episode)
        }
        if let index = data.pets.firstIndex(where: { $0.id == id }) {
            data.pets[index].isArchived = true
            data.pets[index].mode = .baseline
        }
    }

    func restorePet(_ id: UUID) {
        if let index = data.pets.firstIndex(where: { $0.id == id }) {
            data.pets[index].isArchived = false
        }
    }

    func exposures(in episode: Episode) -> [ExposureEvent] {
        let windowStart = episode.start.addingTimeInterval(-72 * 3600)
        let windowEnd = episode.end ?? Date()
        return data.exposures
            .filter { $0.applies(to: episode.petID) && $0.date >= windowStart && $0.date <= windowEnd }
            .sorted { $0.date > $1.date }
    }

    /// A medication exposure in the 72h before this episode opened — used to
    /// frame the episode as possibly expected noise, without diagnosing.
    func medExposureBefore(_ episode: Episode) -> ExposureEvent? {
        data.exposures.first { exposure in
            exposure.kind.isMedication &&
            exposure.applies(to: episode.petID) &&
            episode.start.timeIntervalSince(exposure.date) >= 0 &&
            episode.start.timeIntervalSince(exposure.date) <= 72 * 3600
        }
    }

    func updatePet(_ pet: Pet) {
        if let index = data.pets.firstIndex(where: { $0.id == pet.id }) {
            data.pets[index] = pet
        }
    }

    func addPet(_ pet: Pet) {
        data.pets.append(pet)
    }

    func completeOnboarding() {
        data.hasOnboarded = true
    }

    // MARK: - Unified timeline

    enum TimelineEntry: Identifiable {
        case output(OutputEvent)
        case intervention(Intervention)
        case exposure(ExposureEvent)
        case crossFeed(CrossFeed)

        var id: UUID {
            switch self {
            case .output(let e): return e.id
            case .intervention(let e): return e.id
            case .exposure(let e): return e.id
            case .crossFeed(let e): return e.id
            }
        }

        var date: Date {
            switch self {
            case .output(let e): return e.date
            case .intervention(let e): return e.date
            case .exposure(let e): return e.date
            case .crossFeed(let e): return e.date
            }
        }
    }

    func timeline(for petID: UUID, since: Date) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        entries += data.events.filter { $0.petID == petID && $0.date >= since }.map { .output($0) }
        entries += data.interventions.filter { $0.petID == petID && $0.date >= since }.map { .intervention($0) }
        entries += data.exposures.filter { $0.applies(to: petID) && $0.date >= since }.map { .exposure($0) }
        entries += data.crossFeeds.filter { $0.eaterID == petID && $0.date >= since }.map { .crossFeed($0) }
        return entries.sorted { $0.date > $1.date }
    }

    // MARK: - Lookback (W4)

    struct Lookback {
        var newItems: [Item]
        var crossFeeds: [CrossFeed]
        var interventions: [Intervention]
        var outputs: [OutputEvent]
        var exposures: [ExposureEvent]
    }

    func lookback(petID: UUID, hours: Double = 48) -> Lookback {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let newItemCutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        // Meds and stress stay relevant longer than a meal does.
        let exposureCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let relevantItems = data.items.filter { item in
            guard item.firstIntroduced >= newItemCutoff else { return false }
            switch item.scope {
            case .household: return true
            case .pet(let owner): return owner == petID
            }
        }
        let feeds = data.crossFeeds.filter { $0.date >= cutoff && ($0.eaterID == petID || $0.foodOwnerID == petID) }
        let meds = data.interventions.filter { $0.petID == petID && $0.date >= cutoff }
        let outs = data.events.filter { $0.petID == petID && $0.date >= cutoff }.sorted { $0.date > $1.date }
        let exposed = data.exposures
            .filter { $0.applies(to: petID) && $0.date >= exposureCutoff }
            .sorted { $0.date > $1.date }
        return Lookback(newItems: relevantItems, crossFeeds: feeds, interventions: meds, outputs: outs, exposures: exposed)
    }

    // MARK: - Seed data

    static func seed() -> AppData {
        let now = Date()
        func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 24 * 3600) }
        func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

        let navi = Pet(name: "Navi", species: .dog, breed: "Cattle dog mix", avatar: "🐕",
                       conditions: ["Sensitive gut"], mode: .watch, birthdate: daysAgo(1520))
        let albus = Pet(name: "Albus", species: .dog, breed: "Golden retriever", avatar: "🦮",
                        birthdate: daysAgo(300))
        let arya = Pet(name: "Arya", species: .dog, breed: "Border collie", avatar: "🐶",
                       birthdate: daysAgo(980))

        var seeded = AppData()
        seeded.hasOnboarded = true
        seeded.isDemo = true
        seeded.pets = [navi, albus, arya]

        seeded.items = [
            Item(name: "Hill's i/d", scope: .pet(navi.id), kind: "food", firstIntroduced: daysAgo(220)),
            Item(name: "Puppy kibble", scope: .pet(albus.id), kind: "food", firstIntroduced: daysAgo(90)),
            Item(name: "Salmon kibble", scope: .pet(arya.id), kind: "food", firstIntroduced: daysAgo(300)),
            Item(name: "Bully sticks", scope: .household, kind: "chew", firstIntroduced: daysAgo(200)),
            Item(name: "Yak cheese chew", scope: .household, kind: "chew", firstIntroduced: daysAgo(2.2)),
        ]

        // A resolved past episode for Navi, with the interventions that were tried.
        let pastEpisode = Episode(petID: navi.id, start: daysAgo(61), end: daysAgo(57),
                                  note: "Soft stool after park weekend")
        var oldReading = StoolReading.normal
        oldReading.consistency = .softServe
        seeded.events.append(OutputEvent(petID: navi.id, date: daysAgo(61),
                                         reading: oldReading, tier: .monitor))
        seeded.events.append(OutputEvent(petID: navi.id, date: daysAgo(59),
                                         reading: .normal, tier: .normal))
        seeded.events.append(OutputEvent(petID: navi.id, date: daysAgo(58),
                                         reading: .normal, tier: .normal))
        seeded.events.append(OutputEvent(petID: navi.id, date: daysAgo(57.2),
                                         reading: .normal, tier: .normal))
        seeded.interventions = [
            Intervention(petID: navi.id, episodeID: pastEpisode.id, kind: .fasted, date: daysAgo(61)),
            Intervention(petID: navi.id, episodeID: pastEpisode.id, kind: .blandDiet, date: daysAgo(60)),
            Intervention(petID: navi.id, episodeID: pastEpisode.id, kind: .removedItem, date: daysAgo(60)),
        ]

        // Cross-feeding two days ago: Navi got into Albus's puppy kibble.
        seeded.crossFeeds = [
            CrossFeed(eaterID: navi.id, foodOwnerID: albus.id, amount: "half the bowl", date: daysAgo(2)),
        ]

        // Navi started a new supplement 2.5 days ago — ~34h before the episode.
        seeded.exposures = [
            ExposureEvent(petID: navi.id, kind: .medStarted, note: "joint supplement", date: daysAgo(2.5)),
        ]

        // Active episode: opened yesterday.
        let active = Episode(petID: navi.id, start: daysAgo(1.1), note: "Soft serve since yesterday morning")
        var reading1 = StoolReading.normal
        reading1.consistency = .softServe
        seeded.events.append(OutputEvent(petID: navi.id, date: daysAgo(1.1), reading: reading1, tier: .monitor))
        var reading2 = StoolReading.normal
        reading2.consistency = .littleSoft
        seeded.events.append(OutputEvent(petID: navi.id, date: hoursAgo(5), reading: reading2, tier: .monitor))

        seeded.episodes = [pastEpisode, active]
        return seeded
    }
}

// MARK: - Date helpers

func relativeDay(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

func hoursBetween(_ a: Date, _ b: Date) -> Int {
    Int(abs(b.timeIntervalSince(a)) / 3600)
}

func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

func shortDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
