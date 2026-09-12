import SwiftUI

/// W8 — the vet summary, medication-first. Built for a vet scanning a phone
/// for thirty seconds: what the animal is on, what changed, what the gut did,
/// then flags and possible triggers. Every line is arithmetic over logged
/// events — nothing is generated — and dated facts sit side by side so the
/// vet forms the question instead of the app asking it. The owner's own note
/// is the one line the app doesn't compute.
struct SummarySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let petID: UUID

    @State private var ownerNote = ""
    /// The model's opening line, present only when a key is configured,
    /// there is something to say, and every sentence survived the guards.
    @State private var opening: [String] = []
    @State private var writingOpening = false
    private let windowDays = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if !opening.isEmpty {
                        openingCard
                    } else if writingOpening {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Writing the opening line…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    SectionHeader(title: "Current meds")
                    if activeMeds.isEmpty && stoppedMeds.isEmpty {
                        Text("No meds or supplements.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(activeMeds) { med in MedRow(med: med) }
                            ForEach(stoppedMeds) { med in MedRow(med: med) }
                        }
                    }

                    let changes = changesThisMonth
                    if !changes.isEmpty {
                        SectionHeader(title: "Changed this month")
                        BulletCard(lines: changes)
                    }

                    SectionHeader(title: "What the gut did")
                    BulletCard(lines: gutLines)

                    let flags = flagLog
                    if !flags.isEmpty {
                        SectionHeader(title: "Flags")
                        VStack(spacing: 8) {
                            ForEach(flags) { event in
                                OutputRow(event: event, showsVetScore: true)
                            }
                        }
                    }

                    let triggers = suspectedTriggers
                    if !triggers.isEmpty {
                        SectionHeader(title: "Before episodes (within 72h)")
                        BulletCard(lines: triggers)
                    }

                    SectionHeader(title: "Owner note")
                    PillTextField(placeholder: "The one thing to raise with the vet", text: $ownerNote)

                    Text("Owner-logged observations, not a clinical record.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("Vet summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: summaryText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear { ownerNote = store.pet(petID)?.vetNote ?? "" }
            .onDisappear { saveNote() }
            .task(id: facts.joined(separator: "\n")) {
                // Only when there is something to open with: a med or an
                // episode. One normal log on day one would just be padded.
                guard AIScorer.isConfigured, !activeMeds.isEmpty || !episodesInWindow.isEmpty else {
                    opening = []
                    return
                }
                writingOpening = true
                opening = (try? await AISummary.opening(facts: facts)) ?? []
                writingOpening = false
            }
        }
    }

    // MARK: Opening line

    private var openingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Opening line · written from the log", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(opening.joined(separator: " "))
                .font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.brand.opacity(0.08)))
    }

    /// Everything the model is allowed to know: the bullets on this screen,
    /// one fact per line, in the order they appear. The owner's note is theirs
    /// and stays out.
    private var facts: [String] {
        let pet = store.pet(petID)
        var lines: [String] = []
        let signalment = [pet?.ageLabel, (pet?.breed.isEmpty == false) ? pet?.breed : nil]
            .compactMap { $0 }
            + (pet?.conditions ?? [])
        lines.append("\(pet?.name ?? "The pet")\(signalment.isEmpty ? "" : ", " + signalment.joined(separator: ", ")). Record covers the last \(windowDays) days.")
        for med in activeMeds + stoppedMeds {
            let dose = med.item.dose.isEmpty ? "" : " \(med.item.dose)"
            var line = "\(med.item.isActive ? "Current med" : "Stopped med"): \(med.item.name)\(dose), \(med.whenLine)"
            if let adherence = med.adherenceLine { line += ". \(adherence)" }
            lines.append(line)
        }
        lines += changesThisMonth.map { "Changed this month: \($0)" }
        lines += gutLines
        lines += flagLog.map { event in
            "Flagged stool \(shortDateTime(event.date)): \(event.reading.consistency.label.lowercased()), \(event.reading.color.label.lowercased()), \(event.tier.label.lowercased())"
        }
        lines += suspectedTriggers.map { "Before an episode: \($0)" }
        return lines
    }

    // MARK: Header

    private var header: some View {
        let pet = store.pet(petID)
        let signalment = [pet?.ageLabel, (pet?.breed.isEmpty == false) ? pet?.breed : nil]
            .compactMap { $0 }
            + (pet?.conditions ?? [])
        return VStack(alignment: .leading, spacing: 4) {
            Text(pet?.name ?? "")
                .font(.title2.weight(.bold))
            if !signalment.isEmpty {
                Text(signalment.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text("Last \(windowDays) days")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Meds

    /// One med as the vet wants it: what, how much, how often, since when,
    /// and how reliably it went in. Every number is arithmetic over events.
    struct Med: Identifiable {
        var item: Item
        var whenLine: String
        var adherenceLine: String?
        var id: UUID { item.id }
    }

    private var regimenInWindow: [Item] {
        store.items(for: petID).filter { item in
            item.kind.isRegimen && (item.isActive || (item.stopped ?? .distantPast) >= windowStart)
        }
    }

    private var activeMeds: [Med] {
        regimenInWindow.filter(\.isActive).sorted { $0.firstIntroduced > $1.firstIntroduced }.map(med)
    }

    private var stoppedMeds: [Med] {
        regimenInWindow.filter { !$0.isActive }.sorted { ($0.stopped ?? .distantPast) > ($1.stopped ?? .distantPast) }.map(med)
    }

    private func med(_ item: Item) -> Med {
        var when = item.cadenceLabel
        if let course = item.courseLabel, let end = item.plannedEnd() {
            when += " \(course), through \(shortDate(end))"
        }
        when += " · since \(shortDate(item.firstIntroduced))"
        if let stopped = item.stopped { when += " · stopped \(shortDate(stopped))" }

        var adherence: String?
        if item.interval != nil, let state = store.intervalState(petID: petID, item: item) {
            // A long-term med is judged on the last dose and the next.
            var parts: [String] = []
            if let last = state.last {
                parts.append((last.status == .skipped ? "Last skipped " : "Last given ") + shortDate(last.date))
            } else {
                parts.append("No dose logged yet")
            }
            if state.isCourseComplete {
                parts.append("course complete")
            } else if item.isActive {
                parts.append(state.isOverdue ? "overdue since \(shortDate(state.nextDue))" : "next due \(shortDate(state.nextDue))")
            }
            if let planned = state.plannedDoses {
                parts.append("\(state.dosesGiven) of \(planned) doses given")
            }
            adherence = parts.joined(separator: " · ")
        } else if !item.schedule.isEmpty {
            let counts = store.adherence(for: petID, item: item, from: windowStart)
            if counts.scheduled > 0 {
                adherence = "Given \(counts.given) of \(counts.scheduled) scheduled doses"
                // Only worth saying when tracking began after the start date;
                // otherwise "since" already appears on the line above.
                if item.trackedSince > windowStart,
                   !Calendar.current.isDate(item.trackedSince, inSameDayAs: item.firstIntroduced) {
                    adherence! += " since \(shortDate(item.trackedSince))"
                }
            }
        } else {
            let given = store.intakes(for: petID, itemID: item.id)
                .filter { $0.status == .given && $0.date >= windowStart }.count
            adherence = given == 0 ? nil : "Given \(given) time\(given == 1 ? "" : "s") this month"
        }
        return Med(item: item, whenLine: when, adherenceLine: adherence)
    }

    // MARK: Changes

    /// Starts, stops, misses, overdue doses, finished courses — dated. The
    /// section a vet reads first, so it carries nothing else.
    private var changesThisMonth: [String] {
        var lines: [String] = []
        for item in regimenInWindow where item.firstIntroduced >= windowStart {
            lines.append("Started \(item.name) · \(shortDate(item.firstIntroduced))")
        }
        for item in regimenInWindow {
            if let stopped = item.stopped, stopped >= windowStart {
                lines.append("Stopped \(item.name) · \(shortDate(stopped))")
            }
        }
        let missed = store.missedDoses(for: petID, from: windowStart)
        let byItem = Dictionary(grouping: missed, by: { $0.item.id })
        for (_, misses) in byItem.sorted(by: { $0.value.count > $1.value.count }) {
            guard let name = misses.first?.item.name else { continue }
            let days = Array(Set(misses.map { Calendar.current.startOfDay(for: $0.day) })).sorted()
            let count = misses.count
            var line = "Missed \(count) dose\(count == 1 ? "" : "s") of \(name)"
            if days.count <= 3 {
                line += " · " + days.map(shortDate).joined(separator: ", ")
            } else if let last = days.last {
                line += " · last \(shortDate(last))"
            }
            lines.append(line)
        }
        for due in store.intervalDues(for: petID) where due.state.isOverdue {
            lines.append("\(due.item.name) overdue · was due \(shortDate(due.state.nextDue))")
        }
        for item in store.finishedCourses(for: petID) {
            let end = item.plannedEnd().map { " · \(shortDate($0))" } ?? ""
            lines.append("\(item.name) course finished\(end)")
        }
        return lines
    }

    // MARK: Gut

    /// Status first, then the month's tally, then each med's before-versus-
    /// since. The juxtaposition is the finding; no sentence draws it.
    private var gutLines: [String] {
        var lines: [String] = []
        if let episode = store.activeEpisode(for: petID) {
            var line = "Open episode, day \(episode.durationDays) · \(episode.note)"
            let tried = store.interventions(in: episode)
            if !tried.isEmpty {
                line += " · tried " + tried.map { $0.kind.label.lowercased() }.joined(separator: ", ")
            }
            lines.append(line)
        }
        let outputs = outputsInWindow
        if outputs.isEmpty {
            lines.append("No stools logged in \(windowDays) days")
        } else {
            lines.append("\(Self.tierSummary(outputs)) in \(windowDays) days")
        }
        for episode in episodesInWindow where !episode.isActive {
            var line = "\(shortDate(episode.start)): \(episode.note), resolved in \(episode.durationDays) day\(episode.durationDays == 1 ? "" : "s")"
            let tried = store.interventions(in: episode)
            if !tried.isEmpty {
                line += " · tried " + tried.map { $0.kind.label.lowercased() }.joined(separator: ", ")
            }
            lines.append(line)
        }
        for item in regimenInWindow {
            // Only when both sides have logs — one side alone is not a comparison.
            let courseEnd = item.stopped ?? Date()
            let before = store.data.events.filter { $0.petID == petID && $0.date >= windowStart && $0.date < item.firstIntroduced }
            let since = store.data.events.filter { $0.petID == petID && $0.date >= item.firstIntroduced && $0.date <= courseEnd }
            guard !before.isEmpty, !since.isEmpty else { continue }
            let lead = item.isActive ? "Since \(item.name) (\(shortDate(item.firstIntroduced)))" : "While on \(item.name)"
            lines.append("\(lead): \(Self.tierSummary(since)) · before: \(Self.tierSummary(before))")
        }
        return lines
    }

    /// "6 of 8 normal · 2 concern" — counts by tier, worst first.
    private static func tierSummary(_ events: [OutputEvent]) -> String {
        let normals = events.filter { $0.tier == .normal }.count
        var parts = ["\(normals) of \(events.count) normal"]
        for tier in Tier.allCases.reversed() where tier != .normal {
            let count = events.filter { $0.tier == tier }.count
            if count > 0 { parts.append("\(count) \(tier.label.lowercased())") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Windows

    private var windowStart: Date {
        Date().addingTimeInterval(-Double(windowDays) * 24 * 3600)
    }

    private var outputsInWindow: [OutputEvent] {
        store.data.events.filter { $0.petID == petID && $0.date >= windowStart }
    }

    private var episodesInWindow: [Episode] {
        store.data.episodes
            .filter { $0.petID == petID && ($0.end ?? Date()) >= windowStart }
            .sorted { $0.start > $1.start }
    }

    private var flagLog: [OutputEvent] {
        outputsInWindow.filter { $0.tier >= .concern }.sorted { $0.date > $1.date }
    }

    // MARK: Triggers

    /// Anything logged within 72h before an episode opened — exposures,
    /// cross-feeding, named intake, missed doses, new household items.
    /// Association only, with the counter-evidence alongside: how often the
    /// same thing went in without an episode following.
    private var suspectedTriggers: [String] {
        var lines: [String] = []
        let episodes = episodesInWindow
        for episode in episodes {
            let preWindow = episode.start.addingTimeInterval(-72 * 3600)
            // Named intake: treats, food, chews, and extra (unscheduled) doses.
            // Routine scheduled doses aren't triggers; a *start* is.
            let intakesBefore = store.intakes(for: petID).filter {
                $0.status == .given && $0.slot == nil && $0.date >= preWindow && $0.date <= episode.start
            }
            for intake in intakesBefore {
                guard let item = store.item(intake.itemID) else { continue }
                var line = "\(item.name) (\(item.kind.label.lowercased())), \(hoursBetween(intake.date, episode.start))h before onset"
                let allGiven = store.intakes(for: petID, itemID: item.id).filter { $0.status == .given && $0.date >= windowStart }
                if allGiven.count > 1 {
                    let preceding = allGiven.filter { given in
                        episodes.contains { ep in
                            given.date >= ep.start.addingTimeInterval(-72 * 3600) && given.date <= ep.start
                        }
                    }.count
                    line += " · given \(allGiven.count)× in \(windowDays) days, \(preceding) of those before an episode"
                }
                lines.append(line)
            }
            for item in store.items(for: petID)
            where item.kind.isRegimen && item.firstIntroduced >= preWindow && item.firstIntroduced <= episode.start {
                lines.append("Started \(item.name), \(hoursBetween(item.firstIntroduced, episode.start))h before onset")
            }
            for missed in store.missedDoses(for: petID, from: preWindow, to: episode.start) {
                lines.append("Missed \(missed.item.name) (\(missed.slot.label.lowercased())), \(hoursBetween(missed.due, episode.start))h before onset")
            }
            for exposure in store.data.exposures
            where exposure.applies(to: petID) && exposure.date >= preWindow && exposure.date <= episode.start {
                let note = exposure.note.isEmpty ? "" : " (\(exposure.note))"
                lines.append("\(exposure.kind.label)\(note), \(hoursBetween(exposure.date, episode.start))h before onset")
            }
            for feed in store.data.crossFeeds
            where feed.eaterID == petID && feed.date >= preWindow && feed.date <= episode.start {
                lines.append("Ate \(store.pet(feed.foodOwnerID)?.name ?? "another pet")'s food, \(hoursBetween(feed.date, episode.start))h before onset")
            }
            for item in store.data.items
            where !item.kind.isRegimen && item.applies(to: petID)
                && item.firstIntroduced >= preWindow && item.firstIntroduced <= episode.start
                && !intakesBefore.contains(where: { $0.itemID == item.id }) {
                lines.append("New item in the house: \(item.name)")
            }
        }
        return Array(Set(lines)).sorted()
    }

    // MARK: Owner note

    private func saveNote() {
        guard var pet = store.pet(petID), pet.vetNote != ownerNote else { return }
        pet.vetNote = ownerNote
        store.updatePet(pet)
    }

    // MARK: Share

    /// Plain-text rendering for share / print / paste into a portal message.
    /// Same order as the screen: meds lead.
    private var summaryText: String {
        let pet = store.pet(petID)
        var lines: [String] = []
        let signalment = [pet?.ageLabel, (pet?.breed.isEmpty == false) ? pet?.breed : nil]
            .compactMap { $0 }
            + (pet?.conditions ?? [])
        lines.append("SCOOP: \(pet?.name ?? "")\(signalment.isEmpty ? "" : " (\(signalment.joined(separator: ", ")))"), last \(windowDays) days")
        if !opening.isEmpty {
            lines.append("")
            lines.append(opening.joined(separator: " "))
        }
        lines.append("")
        lines.append("Current meds:")
        if activeMeds.isEmpty && stoppedMeds.isEmpty {
            lines.append("• None")
        }
        for med in activeMeds + stoppedMeds {
            let dose = med.item.dose.isEmpty ? "" : " \(med.item.dose)"
            lines.append("• \(med.item.name)\(dose) — \(med.whenLine)")
            if let adherence = med.adherenceLine { lines.append("  \(adherence)") }
        }
        let changes = changesThisMonth
        if !changes.isEmpty {
            lines.append("")
            lines.append("Changed this month:")
            for change in changes { lines.append("• \(change)") }
        }
        lines.append("")
        lines.append("What the gut did:")
        for line in gutLines { lines.append("• \(line)") }
        let flags = flagLog
        if !flags.isEmpty {
            lines.append("")
            lines.append("Flags:")
            for event in flags {
                lines.append("• \(shortDateTime(event.date)) · \(event.reading.consistency.label) (vet score \(event.reading.consistency.vetScore)), \(event.reading.color.label), \(event.tier.label.lowercased())")
            }
        }
        let triggers = suspectedTriggers
        if !triggers.isEmpty {
            lines.append("")
            lines.append("Before episodes (within 72h):")
            for trigger in triggers { lines.append("• \(trigger)") }
        }
        let note = ownerNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("")
            lines.append("Owner note: \(note)")
        }
        lines.append("")
        lines.append("Owner-logged observations via Scoop. Not a diagnosis.")
        return lines.joined(separator: "\n")
    }
}

/// One med, three lines at most: what and how much, when, how reliably.
struct MedRow: View {
    let med: SummarySheet.Med

    var body: some View {
        let item = med.item
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbol)
                    .foregroundColor(item.isActive ? item.kind.tint : .secondary)
                    .frame(width: 20)
                Text(item.name + (item.dose.isEmpty ? "" : " · \(item.dose)"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(item.isActive ? .primary : .secondary)
                Spacer()
                if !item.isActive {
                    Text("Stopped")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                }
            }
            Text(med.whenLine)
                .font(.caption)
                .foregroundColor(.secondary)
            if let adherence = med.adherenceLine {
                Text(adherence)
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
    }
}

/// A section's bullets in one card, not a card per line.
struct BulletCard: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
    }
}
