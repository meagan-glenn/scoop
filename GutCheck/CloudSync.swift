import CloudKit
import Combine
import UIKit

/// CloudKit household sync (W9). The JSON store stays the local source of
/// truth; this layer mirrors it into a single "Household" record zone via
/// CKSyncEngine. The owner keeps the zone in their private database and
/// shares it zone-wide (CKShare); a partner accepts the invite and reads and
/// writes the same zone through the shared database. No backend.
///
/// Sync design notes:
/// - Each domain record is one CKRecord: the same JSON the local file stores,
///   in a `payload` field, plus a CKAsset for photos. Schema stays in one place.
/// - Conflicts are last-writer-wins per record. Two people rarely edit the
///   same poop; the tradeoff is documented in the README.
/// - `hasOnboarded` is device-local and never syncs.
/// - No iCloud account or no provisioned container: status goes .off and the
///   app is exactly as local-only as it was before this file existed.

enum SyncStatus: Equatable {
    case off(String)
    case starting
    case live(isOwner: Bool)

    var label: String {
        switch self {
        case .off(let reason): return reason
        case .starting: return "Checking iCloud…"
        case .live(let isOwner): return isOwner ? "Syncing via your iCloud" : "Synced to a shared household"
        }
    }
}

@MainActor
final class CloudSync: NSObject, ObservableObject {
    static let shared = CloudSync()

    static let containerID = "iCloud.com.meagan.scoop"
    static let zoneName = "Household"

    @Published var status: SyncStatus = .starting
    @Published var lastSync: Date?

    private(set) weak var store: AppStore?
    let container = CKContainer(identifier: CloudSync.containerID)
    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var state = PersistedState()
    /// An invite that arrived before start() ran (cold launch from a share link).
    private var pendingShareMetadata: CKShare.Metadata?
    /// A share waiting to go up through the private engine's next batch.
    private var pendingShare: CKShare?
    private var savedShare: CKShare?
    private var shareSaveError: Error?
    private var didBootstrap = false

    // MARK: - Persisted sync state

    private struct ZoneRef: Codable {
        var zoneName: String
        var ownerName: String
        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
    }

    private struct PersistedState: Codable {
        var privateState: CKSyncEngine.State.Serialization?
        var sharedState: CKSyncEngine.State.Serialization?
        /// Set when this device joined someone else's household.
        var joinedZone: ZoneRef?
        var didInitialUpload = false
        /// Server system fields per record, so updates carry the change tag.
        var systemFields: [String: Data] = [:]
    }

    private var stateURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloudsync-state.json")
    }

    private func loadState() {
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
        }
    }

    private func saveState() {
        if let encoded = try? JSONEncoder().encode(state) {
            try? encoded.write(to: stateURL)
        }
    }

    // MARK: - Zones

    private var ownZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Where the household lives: someone else's shared zone if we joined one,
    /// otherwise our own private zone.
    private var householdZoneID: CKRecordZone.ID {
        state.joinedZone?.zoneID ?? ownZoneID
    }

    private var householdEngine: CKSyncEngine? {
        state.joinedZone == nil ? privateEngine : sharedEngine
    }

    var isOwner: Bool { state.joinedZone == nil }

    // MARK: - Lifecycle

    func start(store: AppStore) {
        self.store = store
        store.onLocalChange = { [weak self] old, new in
            self?.localDataChanged(old: old, new: new)
        }
        loadState()
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        let accountStatus = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard accountStatus == .available else {
            status = .off("Sign in to iCloud on this device to sync")
            return
        }

        privateEngine = makeEngine(scope: .private, stateData: state.privateState)
        sharedEngine = makeEngine(scope: .shared, stateData: state.sharedState)

        if isOwner {
            privateEngine?.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: ownZoneID)),
            ])
            if !state.didInitialUpload {
                enqueueAllRecords()
                state.didInitialUpload = true
                saveState()
            }
        }

        status = .live(isOwner: isOwner)
        didBootstrap = true
        if let metadata = pendingShareMetadata {
            pendingShareMetadata = nil
            acceptShare(metadata)
        } else {
            await fetchNow()
        }
    }

    private func makeEngine(scope: CKDatabase.Scope, stateData: CKSyncEngine.State.Serialization?) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: container.database(with: scope),
            stateSerialization: stateData,
            delegate: self
        )
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }

    /// Called on scene-foreground; cheap when nothing changed.
    func fetchNow() async {
        guard case .live = status else { return }
        try? await privateEngine?.fetchChanges()
        try? await sharedEngine?.fetchChanges()
    }

    // MARK: - Local → cloud

    private func localDataChanged(old: AppData, new: AppData) {
        guard case .live = status, let engine = householdEngine else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        changes += diff(old.pets, new.pets, prefix: RecordKind.pet)
        changes += diff(old.items, new.items, prefix: RecordKind.item)
        changes += diff(old.events, new.events, prefix: RecordKind.event)
        changes += diff(old.interventions, new.interventions, prefix: RecordKind.intervention)
        changes += diff(old.crossFeeds, new.crossFeeds, prefix: RecordKind.crossFeed)
        changes += diff(old.episodes, new.episodes, prefix: RecordKind.episode)
        changes += diff(old.exposures, new.exposures, prefix: RecordKind.exposure)
        guard !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func diff<T: Identifiable & Equatable>(
        _ old: [T], _ new: [T], prefix: RecordKind
    ) -> [CKSyncEngine.PendingRecordZoneChange] where T.ID == UUID {
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newIDs = Set(new.map(\.id))
        for element in new where oldByID[element.id] != element {
            changes.append(.saveRecord(recordID(prefix, element.id)))
        }
        for element in old where !newIDs.contains(element.id) {
            changes.append(.deleteRecord(recordID(prefix, element.id)))
        }
        return changes
    }

    private func enqueueAllRecords() {
        guard let data = store?.data else { return }
        localDataChanged(old: AppData(), new: data)
    }

    // MARK: - Record mapping

    enum RecordKind: String, CaseIterable {
        case pet = "Pet"
        case item = "Item"
        case event = "OutputEvent"
        case intervention = "Intervention"
        case crossFeed = "CrossFeed"
        case episode = "Episode"
        case exposure = "Exposure"
    }

    private func recordID(_ kind: RecordKind, _ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(kind.rawValue)_\(id.uuidString)", zoneID: householdZoneID)
    }

    private func parse(recordName: String) -> (RecordKind, UUID)? {
        let parts = recordName.split(separator: "_", maxSplits: 1)
        guard parts.count == 2,
              let kind = RecordKind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        return (kind, id)
    }

    /// Build the outgoing record: cached system fields (change tag) + payload.
    private func makeRecord(for id: CKRecord.ID) -> CKRecord? {
        if id.recordName == CKRecordNameZoneWideShare, let pendingShare, pendingShare.recordID == id {
            return pendingShare
        }
        guard let data = store?.data, let (kind, uuid) = parse(recordName: id.recordName) else { return nil }

        var payload: Data?
        var photoFilename: String?
        let encoder = JSONEncoder()
        switch kind {
        case .pet:
            if let pet = data.pets.first(where: { $0.id == uuid }) {
                payload = try? encoder.encode(pet)
                photoFilename = pet.photoFilename
            }
        case .item:
            payload = data.items.first { $0.id == uuid }.flatMap { try? encoder.encode($0) }
        case .event:
            if let event = data.events.first(where: { $0.id == uuid }) {
                payload = try? encoder.encode(event)
                photoFilename = event.photoFilename
            }
        case .intervention:
            payload = data.interventions.first { $0.id == uuid }.flatMap { try? encoder.encode($0) }
        case .crossFeed:
            payload = data.crossFeeds.first { $0.id == uuid }.flatMap { try? encoder.encode($0) }
        case .episode:
            payload = data.episodes.first { $0.id == uuid }.flatMap { try? encoder.encode($0) }
        case .exposure:
            payload = data.exposures.first { $0.id == uuid }.flatMap { try? encoder.encode($0) }
        }
        guard let payload else { return nil } // deleted locally since being queued

        let record: CKRecord
        if let cached = state.systemFields[id.recordName],
           let coder = try? NSKeyedUnarchiver(forReadingFrom: cached) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder) ?? CKRecord(recordType: kind.rawValue, recordID: id)
        } else {
            record = CKRecord(recordType: kind.rawValue, recordID: id)
        }
        record["payload"] = payload as CKRecordValue
        if let photoFilename, let store {
            let url = store.photoURL(photoFilename)
            if FileManager.default.fileExists(atPath: url.path) {
                record["photo"] = CKAsset(fileURL: url)
            }
        }
        return record
    }

    private func cacheSystemFields(of record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        state.systemFields[record.recordID.recordName] = archiver.encodedData
    }

    // MARK: - Cloud → local

    private func applyRemote(modified: [CKRecord], deleted: [CKRecord.ID]) {
        guard let store else { return }
        store.isApplyingRemote = true
        defer { store.isApplyingRemote = false }

        var data = store.data
        for record in modified {
            upsert(record, into: &data)
            cacheSystemFields(of: record)
        }
        for id in deleted {
            remove(recordName: id.recordName, from: &data)
            state.systemFields[id.recordName] = nil
        }
        // A household arriving over sync is an onboarded household.
        if !data.pets.isEmpty { data.hasOnboarded = true }
        store.data = data
        lastSync = Date()
        saveState()
    }

    private func upsert(_ record: CKRecord, into data: inout AppData) {
        guard let payload = record["payload"] as? Data,
              let (kind, _) = parse(recordName: record.recordID.recordName)
        else { return }
        let decoder = JSONDecoder()

        // Photos ride along as assets; copy into the local photos directory
        // under the filename the payload references.
        if let asset = record["photo"] as? CKAsset, let assetURL = asset.fileURL, let store {
            let filename = (try? decoder.decode(PhotoCarrier.self, from: payload))?.photoFilename
            if let filename {
                let destination = store.photoURL(filename)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.copyItem(at: assetURL, to: destination)
                }
            }
        }

        switch kind {
        case .pet:
            if let value = try? decoder.decode(Pet.self, from: payload) { replace(value, in: &data.pets) }
        case .item:
            if let value = try? decoder.decode(Item.self, from: payload) { replace(value, in: &data.items) }
        case .event:
            if let value = try? decoder.decode(OutputEvent.self, from: payload) { replace(value, in: &data.events) }
        case .intervention:
            if let value = try? decoder.decode(Intervention.self, from: payload) { replace(value, in: &data.interventions) }
        case .crossFeed:
            if let value = try? decoder.decode(CrossFeed.self, from: payload) { replace(value, in: &data.crossFeeds) }
        case .episode:
            if let value = try? decoder.decode(Episode.self, from: payload) { replace(value, in: &data.episodes) }
        case .exposure:
            if let value = try? decoder.decode(ExposureEvent.self, from: payload) { replace(value, in: &data.exposures) }
        }
    }

    /// Only used to pull the photo filename out of a payload without knowing
    /// its full type.
    private struct PhotoCarrier: Codable {
        var photoFilename: String?
    }

    private func replace<T: Identifiable>(_ value: T, in array: inout [T]) {
        if let index = array.firstIndex(where: { $0.id == value.id }) {
            array[index] = value
        } else {
            array.append(value)
        }
    }

    private func remove(recordName: String, from data: inout AppData) {
        guard let (kind, id) = parse(recordName: recordName) else { return }
        switch kind {
        case .pet: data.pets.removeAll { $0.id == id }
        case .item: data.items.removeAll { $0.id == id }
        case .event: data.events.removeAll { $0.id == id }
        case .intervention: data.interventions.removeAll { $0.id == id }
        case .crossFeed: data.crossFeeds.removeAll { $0.id == id }
        case .episode: data.episodes.removeAll { $0.id == id }
        case .exposure: data.exposures.removeAll { $0.id == id }
        }
    }

    // MARK: - Sharing

    /// Append a raw diagnostic dump to Documents/scoop-debug.log so it can be
    /// pulled off a device with devicectl when no console is attached.
    static func debugDump(_ lines: String...) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scoop-debug.log")
        let text = "\n===== \(Date()) =====\n" + lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Unwrap CloudKit's nested errors into one readable line for the UI.
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: Error? = error
        var depth = 0
        while let e = current, depth < 4 {
            let ns = e as NSError
            var line = "\(ns.domain) \(ns.code)"
            if let ck = e as? CKError { line = "CloudKit \(ck.code) (\(ck.errorCode))" }
            if let server = ns.userInfo["ServerErrorDescription"] as? String { line += ": \(server)" }
            else if let desc = ns.userInfo[NSLocalizedDescriptionKey] as? String { line += ": \(desc)" }
            if let partial = ns.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
               let first = partial.values.first {
                line += " [partial: \(describe(first))]"
            }
            parts.append(line)
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return parts.joined(separator: " <- ")
    }

    /// Fetch the household zone's existing zone-wide share, or create one.
    /// The household's share if one has been created, without creating one.
    func existingShare() async throws -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ownZoneID)
        return try? await container.privateCloudDatabase.record(for: shareID) as? CKShare
    }

    func fetchOrCreateShare() async throws -> CKShare {
        if let savedShare { return savedShare }
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ownZoneID)
        if let existing = try? await database.record(for: shareID) as? CKShare {
            savedShare = existing
            return existing
        }
        guard let engine = privateEngine else {
            throw NSError(domain: "Scoop", code: 3, userInfo: [NSLocalizedDescriptionKey: "Sync isn't running yet. Try again in a moment."])
        }
        // Route the share through the sync engine, the same path every other
        // record takes. Saving it out-of-band while the engine owns the zone
        // is what CloudKit rejects with an internal error.
        let share = CKShare(recordZoneID: ownZoneID)
        share[CKShare.SystemFieldKey.title] = "Scoop household" as CKRecordValue
        // Created private; the system sharing sheet lets the owner add
        // people or switch to "anyone with the link". Setting a public
        // permission at creation is what the server rejects (15 / 2000).
        share.publicPermission = .none
        pendingShare = share
        shareSaveError = nil
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ownZoneID))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(share.recordID)])
        var sendError: Error?
        do { try await engine.sendChanges() } catch { sendError = error }
        if let savedShare { return savedShare }
        if let error = (shareSaveError ?? sendError) {
            CloudSync.debugDump("share save failed",
                                "shareSaveError: \(String(reflecting: shareSaveError as Any))",
                                "sendError: \(String(reflecting: sendError as Any))",
                                "zone: \(ownZoneID)")
            throw NSError(domain: "Scoop", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: CloudSync.describe(error)])
        }
        // Nothing came back yet; read it from the server.
        if let fetched = try? await database.record(for: shareID) as? CKShare {
            savedShare = fetched
            return fetched
        }
        throw NSError(domain: "Scoop", code: 4, userInfo: [NSLocalizedDescriptionKey: "The share didn't come back from iCloud. Try again."])
    }

    /// The partner tapped the invite link; from here the household lives in
    /// the owner's zone via the shared database. Local data is replaced by
    /// what syncs down (v1 rule: joining replaces, documented).
    func acceptShare(_ metadata: CKShare.Metadata) {
        guard didBootstrap else {
            pendingShareMetadata = metadata
            return
        }
        Task {
            do {
                try await container.accept(metadata)
                let zoneID = metadata.share.recordID.zoneID
                state.joinedZone = ZoneRef(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
                state.didInitialUpload = true // participants never bulk-upload local data
                saveState()
                status = .live(isOwner: false)
                try? await sharedEngine?.fetchChanges()
            } catch {
                status = .off("Couldn't join the household: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    private func handle(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let update):
            if engine.database.databaseScope == .private {
                state.privateState = update.stateSerialization
            } else {
                state.sharedState = update.stateSerialization
            }
            saveState()

        case .accountChange:
            Task { await bootstrap() }

        case .fetchedRecordZoneChanges(let changes):
            applyRemote(
                modified: changes.modifications.map(\.record),
                deleted: changes.deletions.map(\.recordID)
            )

        case .fetchedDatabaseChanges(let changes):
            // Losing the joined zone means the owner stopped sharing.
            for deletion in changes.deletions where deletion.zoneID == state.joinedZone?.zoneID {
                state.joinedZone = nil
                saveState()
                status = .off("The shared household was removed")
            }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                if let share = record as? CKShare {
                    savedShare = share
                    pendingShare = nil
                    continue
                }
                cacheSystemFields(of: record)
            }
            for failure in sent.failedRecordSaves {
                if failure.record.recordID.recordName == CKRecordNameZoneWideShare {
                    shareSaveError = failure.error
                    pendingShare = nil
                    continue
                }
                switch failure.error.code {
                case .serverRecordChanged:
                    // Someone else wrote first. Take their change tag and
                    // resend ours: last writer wins, per record.
                    if let server = failure.error.serverRecord {
                        cacheSystemFields(of: server)
                    }
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                case .zoneNotFound:
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: failure.record.recordID.zoneID))])
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                default:
                    break // transient; the engine retries on its own schedule
                }
            }
            saveState()
            lastSync = Date()

        case .didFetchChanges:
            lastSync = Date()

        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.makeRecord(for: recordID)
        }
    }
}
