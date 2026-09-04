import SwiftUI

/// Per-pet screen, ordered by what an owner actually reaches for here:
/// 1. the timeline, 2. a vet summary (they're standing in the exam room),
/// 3. editing what's going on with this animal. Logging an output is demoted
/// to a toolbar icon — that mostly happens from the home screen.
struct PetScreen: View {
    @EnvironmentObject var store: AppStore
    let petID: UUID

    @State private var showCapture = false
    @State private var showSummary = false
    @State private var showEdit = false
    @State private var showRegimen = false
    @State private var showIntake = false
    @State private var showEndEpisodeConfirm = false

    var body: some View {
        let pet = store.pet(petID)
        let episode = store.activeEpisode(for: petID)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let episode = episode {
                    statusCard(episode: episode)
                } else {
                    baselineCard
                }

                // Vet summary is the marquee action: one tap, exam-room ready.
                HStack(spacing: 10) {
                    Button {
                        showSummary = true
                    } label: {
                        Label("Vet summary", systemImage: "doc.text.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showRegimen = true
                    } label: {
                        Label("Meds", systemImage: "pills.fill")
                            .padding(.vertical, 8)
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                            .padding(.vertical, 8)
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.bordered)
                }

                regimenSection

                if let episode = episode {
                    episodeContext(episode: episode)
                }

                SectionHeader(title: "Timeline")
                timelineSection(episode: episode)

                if episode == nil {
                    let past = store.resolvedEpisodes(for: petID)
                    if !past.isEmpty {
                        SectionHeader(title: "Past episodes")
                        ForEach(past) { pastEpisode in
                            EpisodeCard(episode: pastEpisode)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("\(pet?.avatar ?? "") \(pet?.name ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showIntake = true
                } label: {
                    Image(systemName: "fork.knife")
                }
                Button {
                    showCapture = true
                } label: {
                    Image(systemName: "camera.fill")
                }
            }
        }
        .sheet(isPresented: $showCapture) {
            CaptureSheet(petID: petID)
        }
        .sheet(isPresented: $showRegimen) {
            RegimenSheet(petID: petID)
        }
        .sheet(isPresented: $showIntake) {
            IntakeSheet(petID: petID)
        }
        .sheet(isPresented: $showSummary) {
            SummarySheet(petID: petID)
        }
        .sheet(isPresented: $showEdit) {
            if let pet = pet {
                PetEditSheet(pet: pet)
            }
        }
    }

    // MARK: Regimen (today's checklist + what they're on)

    @ViewBuilder
    private var regimenSection: some View {
        let regimen = store.regimen(for: petID)
        if !regimen.isEmpty {
            SectionHeader(title: regimen.contains(where: \.isScheduled) ? "Today's meds" : "Meds")
            DoseChecklist(petID: petID)
            IntervalChecklist(petID: petID)
            let asNeeded = regimen.filter { !$0.isScheduled && !$0.isRecurring }
            if !asNeeded.isEmpty {
                Text("As needed: " + asNeeded.map { $0.name + ($0.dose.isEmpty ? "" : " \($0.dose)") }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Status

    private func statusCard(episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Watch mode · Day \(episode.durationDays)")
                    .font(.headline)
                Spacer()
                TierBadge(tier: worstTier(in: episode))
            }
            Text(episode.note)
                .font(.subheadline)
                .foregroundColor(.secondary)
            ResolutionDots(progress: store.resolutionProgress(for: episode))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tier.monitor.color.opacity(0.10)))
    }

    private var baselineCard: some View {
        let pet = store.pet(petID)
        return VStack(alignment: .leading, spacing: 6) {
            Label("Baseline: all quiet", systemImage: "moon.zzz.fill")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Every log quietly builds \(pet?.name ?? "their") normal for the day it matters.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radius).fill(DS.surface))
    }

    // MARK: Episode context (med framing, resolve)

    @ViewBuilder
    private func episodeContext(episode: Episode) -> some View {
        let logged = store.interventions(in: episode)

        if let medStart = store.medStartBefore(episode) {
            let noteSuffix = medStart.name.isEmpty ? "" : " (\(medStart.name))"
            let phrase = medStart.isChange ? "a med change" : "starting a med"
            Label {
                Text("This began \(hoursBetween(medStart.date, episode.start))h after \(phrase)\(noteSuffix). That timing is common with med changes and worth mentioning to your vet.")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "pills.fill")
                    .foregroundColor(Tier.concern.color)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.radius).fill(Tier.concern.color.opacity(0.08)))
        }

        if store.resolutionProgress(for: episode) >= 3 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Looks like this cleared up", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Tier.normal.color)
                Text("Three normal outputs in a row. Mark it resolved?")
                    .font(.subheadline)
                Button {
                    store.resolveEpisode(episode)
                } label: {
                    Text("Mark resolved")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tier.normal.color)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Tier.normal.color.opacity(0.10)))
        }

        // One-tap interventions, compact horizontal strip.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InterventionKind.allCases) { kind in
                    let alreadyLogged = logged.contains { $0.kind == kind }
                    Chip(label: kind.label, isSelected: alreadyLogged, tint: .accentColor) {
                        if !alreadyLogged {
                            store.addIntervention(kind: kind, petID: petID)
                        }
                    }
                }
            }
        }

        // Escape hatch: episodes must be closable even if logging stopped —
        // otherwise "better and busy" leaves watch mode on forever.
        if store.resolutionProgress(for: episode) < 3 {
            Button {
                showEndEpisodeConfirm = true
            } label: {
                Text("All better? End this episode")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .confirmationDialog("End this episode?", isPresented: $showEndEpisodeConfirm, titleVisibility: .visible) {
                Button("End it, back to baseline") {
                    store.resolveEpisode(episode)
                }
                Button("Keep watching", role: .cancel) {}
            } message: {
                Text("Usually this happens on its own after 3 normal logs. Ending it early is fine if things cleared up and you stopped logging.")
            }
        }
    }

    // MARK: Timeline

    @ViewBuilder
    private func timelineSection(episode: Episode?) -> some View {
        let since = episode.map { $0.start.addingTimeInterval(-72 * 3600) }
            ?? Date().addingTimeInterval(-30 * 24 * 3600)
        let entries = store.timeline(for: petID, since: since)

        if entries.isEmpty {
            Text("Nothing in the last 30 days.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        ForEach(entries) { entry in
            timelineRow(entry)
                .contextMenu {
                    Button(role: .destructive) {
                        delete(entry)
                    } label: {
                        Label("Delete entry", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func timelineRow(_ entry: AppStore.TimelineEntry) -> some View {
        switch entry {
        case .output(let event):
            OutputRow(event: event)
        case .intervention(let intervention):
            HStack(spacing: 10) {
                Image(systemName: intervention.kind.symbol)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                Text(intervention.kind.label)
                    .font(.subheadline)
                Spacer()
                Text(shortDateTime(intervention.date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
        case .exposure(let exposure):
            ExposureRow(exposure: exposure)
        case .intake(let intake):
            IntakeRow(intake: intake)
        case .crossFeed(let feed):
            HStack(spacing: 10) {
                Image(systemName: "fork.knife.circle.fill")
                    .foregroundColor(Tier.concern.color)
                    .frame(width: 24)
                Text("Ate \(store.pet(feed.foodOwnerID)?.name ?? "?")'s food (\(feed.amount))")
                    .font(.subheadline)
                Spacer()
                Text(shortDateTime(feed.date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
        }
    }

    private func delete(_ entry: AppStore.TimelineEntry) {
        switch entry {
        case .output(let event): store.removeEvent(id: event.id)
        case .intervention(let intervention): store.removeIntervention(id: intervention.id)
        case .exposure(let exposure): store.removeExposure(id: exposure.id)
        case .crossFeed(let feed): store.removeCrossFeed(id: feed.id)
        case .intake(let intake): store.removeIntake(id: intake.id)
        }
    }

    private func worstTier(in episode: Episode) -> Tier {
        store.events(in: episode).map { $0.tier }.max() ?? .normal
    }
}
