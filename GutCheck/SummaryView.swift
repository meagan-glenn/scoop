import SwiftUI

/// W8 — the vet summary. One tap from the pet screen, built for the moment
/// you're standing in the exam room. Headline first, detail behind it,
/// questions phrased as questions — never conclusions.
struct SummarySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let petID: UUID

    private let windowDays = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headlineCard

                    if let episode = store.activeEpisode(for: petID) {
                        currentEpisodeCard(episode)
                    }

                    let episodes = episodesInWindow
                    if !episodes.isEmpty {
                        SectionHeader(title: "Episodes")
                        ForEach(episodes) { episode in
                            EpisodeCard(episode: episode)
                        }
                    }

                    let meds = medBlocks
                    if !meds.isEmpty {
                        SectionHeader(title: "Meds & supplements")
                        ForEach(meds) { block in
                            MedBlockView(block: block)
                        }
                    }

                    let triggers = suspectedTriggers
                    if !triggers.isEmpty {
                        SectionHeader(title: "Preceded episodes by ≤72h")
                        ForEach(triggers, id: \.self) { trigger in
                            Label(trigger, systemImage: "questionmark.circle")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
                        }
                    }

                    let flags = flagLog
                    if !flags.isEmpty {
                        SectionHeader(title: "Flag log")
                        ForEach(flags) { event in
                            OutputRow(event: event)
                        }
                    }

                    SectionHeader(title: "Questions for the vet")
                    ForEach(vetQuestions, id: \.self) { question in
                        Label(question, systemImage: "text.bubble")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
                    }

                    Text("Owner-logged observations, not a clinical record. Nothing here is a diagnosis.")
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
        }
    }

    // MARK: Pieces

    private var headlineCard: some View {
        let pet = store.pet(petID)
        let outputs = outputsInWindow
        let normals = outputs.filter { $0.tier == .normal }.count
        let signalment = [pet?.ageLabel, (pet?.breed.isEmpty == false) ? pet?.breed : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(pet?.name ?? ""), last \(windowDays) days")
                .font(.title3.weight(.bold))
            if !signalment.isEmpty {
                Text(signalment)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("\(episodesInWindow.count) episode\(episodesInWindow.count == 1 ? "" : "s") · \(normals) of \(outputs.count) logged stools normal")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let pet = pet, !pet.conditions.isEmpty {
                Text("Known conditions: \(pet.conditions.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.10)))
    }

    private func currentEpisodeCard(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Open episode · Day \(episode.durationDays)", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Tier.monitor.color)
            Text(episode.note)
                .font(.subheadline)
            let used = store.interventions(in: episode)
            if !used.isEmpty {
                Text("Tried so far: " + used.map { $0.kind.label.lowercased() }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tier.monitor.color.opacity(0.10)))
    }

    // MARK: Computations

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

    /// One med or supplement, as the vet wants it: what, since when, how
    /// reliably it went in, and what the stools did before versus since.
    /// Every number is arithmetic over logged events.
    struct MedBlock: Identifiable {
        var item: Item
        var statusLine: String
        var adherenceLine: String?
        var beforeLine: String?
        var sinceLine: String?
        var id: UUID { item.id }
    }

    private var medBlocks: [MedBlock] {
        let items = store.items(for: petID).filter { item in
            item.kind.isRegimen && (item.isActive || (item.stopped ?? .distantPast) >= windowStart)
        }
        return items
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                return a.firstIntroduced > b.firstIntroduced
            }
            .map { item in
                let when = item.schedule.isEmpty ? "as needed" : item.schedule.map { $0.label.lowercased() }.joined(separator: " & ")
                var status = "\(item.dose.isEmpty ? "" : item.dose + " · ")\(when) · started \(shortDate(item.firstIntroduced))"
                if let stopped = item.stopped { status += " · stopped \(shortDate(stopped))" }

                var adherence: String?
                if !item.schedule.isEmpty {
                    let counts = store.adherence(for: petID, item: item, from: windowStart)
                    if counts.scheduled > 0 {
                        adherence = "Given \(counts.given) of \(counts.scheduled) scheduled doses"
                        if item.trackedSince > windowStart {
                            adherence! += " since \(shortDate(item.trackedSince))"
                        }
                    }
                } else {
                    let given = store.intakes(for: petID, itemID: item.id)
                        .filter { $0.status == .given && $0.date >= windowStart }.count
                    adherence = given == 0 ? nil : "Given \(given) time\(given == 1 ? "" : "s") in the window"
                }

                // Stools before the start vs. while on it. Only shown when
                // both sides have logs — one side alone is not a comparison.
                let courseEnd = item.stopped ?? Date()
                let before = store.data.events.filter { $0.petID == petID && $0.date >= windowStart && $0.date < item.firstIntroduced }
                let since = store.data.events.filter { $0.petID == petID && $0.date >= item.firstIntroduced && $0.date <= courseEnd }
                var beforeLine: String?
                var sinceLine: String?
                if !before.isEmpty, !since.isEmpty {
                    beforeLine = "Before: " + Self.tierSummary(before)
                    sinceLine = (item.isActive ? "Since: " : "While on it: ") + Self.tierSummary(since)
                }
                return MedBlock(item: item, statusLine: status, adherenceLine: adherence, beforeLine: beforeLine, sinceLine: sinceLine)
            }
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

    private var vetQuestions: [String] {
        var questions: [String] = []
        for episode in episodesInWindow {
            if let med = store.medStartBefore(episode) {
                let name = med.name.isEmpty ? "a recent med change" : med.name
                questions.append("Symptoms began ~\(hoursBetween(med.date, episode.start))h after \(name). Could they be related?")
            }
        }
        for block in medBlocks where block.item.isActive {
            if let since = block.sinceLine, let before = block.beforeLine {
                questions.append("\(block.item.name): \(before.lowercased()); \(since.lowercased()). Keep going, adjust, or stop?")
            } else if block.item.kind == .med {
                questions.append("\(block.item.name): still the right call, and for how long?")
            }
        }
        let missedTotal = store.missedDoses(for: petID, from: windowStart).count
        if missedTotal >= 3 {
            questions.append("\(missedTotal) scheduled doses were missed this month. Does that change the read on whether it's working?")
        }
        if !suspectedTriggers.isEmpty {
            questions.append("Do any of the items or events preceding episodes warrant an elimination trial?")
        }
        if questions.isEmpty {
            questions.append("Anything in this pattern that warrants tests or a diet change?")
        }
        return Array(Set(questions)).sorted()
    }

    /// Plain-text rendering for share / print / paste into a portal message.
    private var summaryText: String {
        let pet = store.pet(petID)
        let outputs = outputsInWindow
        let normals = outputs.filter { $0.tier == .normal }.count
        var lines: [String] = []
        let signalment = [(pet?.breed.isEmpty == false) ? pet?.breed : nil, pet?.ageLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
        lines.append("SCOOP: \(pet?.name ?? "")\(signalment.isEmpty ? "" : " (\(signalment))"), last \(windowDays) days")
        lines.append("\(episodesInWindow.count) episode(s) · \(normals) of \(outputs.count) logged stools normal")
        if let pet = pet, !pet.conditions.isEmpty {
            lines.append("Known conditions: \(pet.conditions.joined(separator: ", "))")
        }
        lines.append("")
        for episode in episodesInWindow {
            let status = episode.isActive ? "OPEN, day \(episode.durationDays)" : "resolved in \(episode.durationDays) days"
            lines.append("• \(shortDate(episode.start)) · \(episode.note) (\(status))")
            let tried = store.interventions(in: episode)
            if !tried.isEmpty {
                lines.append("  Tried: \(tried.map { $0.kind.label.lowercased() }.joined(separator: ", "))")
            }
        }
        if !medBlocks.isEmpty {
            lines.append("")
            lines.append("Meds & supplements:")
            for block in medBlocks {
                lines.append("• \(block.item.name) — \(block.statusLine)")
                if let adherence = block.adherenceLine { lines.append("  \(adherence)") }
                if let before = block.beforeLine, let since = block.sinceLine { lines.append("  \(before) · \(since)") }
            }
        }
        if !suspectedTriggers.isEmpty {
            lines.append("")
            lines.append("Preceded episodes by ≤72h:")
            for trigger in suspectedTriggers { lines.append("• \(trigger)") }
        }
        if !flagLog.isEmpty {
            lines.append("")
            lines.append("Flag log:")
            for event in flagLog {
                lines.append("• \(shortDateTime(event.date)) · \(event.reading.consistency.label) (vet score \(event.reading.consistency.vetScore)), \(event.reading.color.label), tier \(event.tier.label)")
            }
        }
        lines.append("")
        lines.append("Questions:")
        for question in vetQuestions { lines.append("• \(question)") }
        lines.append("")
        lines.append("Owner-logged observations via Scoop. Not a diagnosis.")
        return lines.joined(separator: "\n")
    }
}

/// One med as a card: name and dose up top, the facts underneath.
struct MedBlockView: View {
    let block: SummarySheet.MedBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: block.item.kind.symbol)
                    .foregroundColor(block.item.isActive ? block.item.kind.tint : .secondary)
                Text(block.item.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !block.item.isActive {
                    Text("Stopped")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                }
            }
            Text(block.statusLine)
                .font(.caption)
                .foregroundColor(.secondary)
            if let adherence = block.adherenceLine {
                Text(adherence)
                    .font(.caption)
            }
            if let before = block.beforeLine, let since = block.sinceLine {
                Text(before)
                    .font(.caption)
                Text(since)
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
    }
}
