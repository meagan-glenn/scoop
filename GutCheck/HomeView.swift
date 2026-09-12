import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showSomethingsOff = false
    @State private var showCapture = false
    @State private var showCrossFeed = false
    @State private var showExposure = false
    @State private var showIntake = false
    @State private var showAddPet = false
    @State private var showArchived = false
    @State private var showSync = false
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Only when there's something to say. On a quiet day the
                    // pet cards speak for themselves.
                    if let greeting {
                        Text(greeting)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if store.data.isDemo {
                        DemoBanner()
                    }

                    // The household is the hero — 95% of opens are healthy days,
                    // and the pets are why anyone is here. No header: three
                    // pet cards are self-evidently the household.
                    ForEach(store.activePets) { pet in
                        VStack(spacing: 8) {
                            NavigationLink {
                                PetScreen(petID: pet.id)
                            } label: {
                                PetCard(pet: pet)
                            }
                            .buttonStyle(.plain)
                            // Today's doses, one tap per slot. Lives outside
                            // the link so a tap on it never navigates.
                            DoseStrip(petID: pet.id)
                                .padding(.horizontal, 4)
                        }
                    }

                    // The multi-pet nudge (W10): a quiet card while the house
                    // has one animal, then it retires to the toolbar plus.
                    if store.activePets.count < 2 {
                        Button {
                            showAddPet = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                Text("Add an animal")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.secondary.opacity(0.35),
                                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    let archived = store.data.pets.filter { $0.isArchived }
                    if !archived.isEmpty {
                        Button("Archived animals (\(archived.count))") {
                            showArchived = true
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                    }

                    // Secondary logging, deliberately quieter than the pet
                    // cards: icons on the page, not a second row of buttons.
                    HStack(alignment: .top, spacing: 4) {
                        quickAction("Something's off", symbol: "exclamationmark.bubble") { showSomethingsOff = true }
                        quickAction("Food & meds", symbol: "pills") { showIntake = true }
                        // Food theft needs someone to steal from.
                        if store.activePets.count >= 2 {
                            quickAction("Food theft", symbol: "fork.knife") { showCrossFeed = true }
                        }
                        quickAction("Stress & events", symbol: "cloud.bolt") { showExposure = true }
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Scoop")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Sync status and the invite live behind the icon; the
                    // symbol itself says whether the household is shared.
                    // Hidden in the demo — pretend animals don't sync.
                    if !store.data.isDemo {
                        Button {
                            showSync = true
                        } label: {
                            Image(systemName: syncRowSymbol)
                        }
                        .accessibilityLabel(syncRowLabel)
                    }
                    if store.activePets.count >= 2 {
                        Button {
                            showAddPet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add an animal")
                    }
                }
            }
            // Camera-first (PRD principle 2): the one thing someone standing
            // over a bad stool wants is the camera. Watch mode follows from
            // an abnormal log rather than being a separate front door.
            .safeAreaInset(edge: .bottom) {
                Button {
                    showCapture = true
                } label: {
                    Label("Log a poop", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .background(.thinMaterial)
            }
            .sheet(isPresented: $showSomethingsOff) {
                SomethingsOffSheet()
            }
            .sheet(isPresented: $showCapture) {
                CaptureSheet(petID: defaultCapturePet)
            }
            .sheet(isPresented: $showCrossFeed) {
                CrossFeedSheet()
            }
            .sheet(isPresented: $showExposure) {
                ExposureSheet()
            }
            .sheet(isPresented: $showIntake) {
                IntakeSheet(petID: store.activePets.count == 1 ? defaultCapturePet : nil)
            }
            .sheet(isPresented: $showAddPet) {
                AddPetSheet()
            }
            .sheet(isPresented: $showArchived) {
                ArchivedPetsSheet()
            }
            .sheet(isPresented: $showSync) {
                SyncSheet()
            }
        }
    }

    private func quickAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(DS.surface))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Only spoken when an episode is open; a quiet day needs no caption.
    private var greeting: String? {
        let watching = store.activePets.filter { $0.mode != .baseline }
        guard !watching.isEmpty else { return nil }
        let names = watching.map(\.name).joined(separator: " and ")
        return "Keeping an eye on \(names). You've got this."
    }

    private var syncRowLabel: String {
        switch sync.status {
        case .live(true): return "Share with your household"
        case .live(false): return "Shared household"
        case .starting: return "Household sync"
        case .off: return "Household sync is off"
        }
    }

    private var syncRowSymbol: String {
        if case .live = sync.status { return "checkmark.icloud" }
        return "icloud"
    }

    /// Pre-select the pet most likely being logged: first one in watch mode.
    private var defaultCapturePet: UUID? {
        let watched = store.activePets.first { $0.mode != .baseline }
        return (watched ?? store.activePets.first)?.id
    }
}

/// The demo is a clearly-marked sandbox: pretend animals, no sync, and one
/// obvious door back out to set up a real household.
struct DemoBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You're in the demo household", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            Text("Everything here is pretend and stays on this phone. Nothing syncs to your iCloud.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Exit and set up your own") {
                store.exitDemo()
                CloudSync.shared.demoEnded()
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(DS.brand.opacity(0.10))
    }
}

/// Archived animals: out of the household, history kept, one tap to return.
struct ArchivedPetsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.data.pets.filter { $0.isArchived }) { pet in
                    HStack(spacing: 12) {
                        PetAvatar(pet: pet, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pet.name)
                                .font(.headline)
                            Text(pet.breed.isEmpty ? pet.species.rawValue : pet.breed)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            store.restorePet(pet.id)
                            if store.data.pets.filter({ $0.isArchived }).isEmpty {
                                dismiss()
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PetCard: View {
    @EnvironmentObject var store: AppStore
    let pet: Pet

    var body: some View {
        let episode = store.activeEpisode(for: pet.id)
        // The card wears the episode's worst tier, not a fixed amber.
        let tier = episode.map { store.episodeTier($0) }
        HStack(spacing: 14) {
            PetAvatar(pet: pet, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pet.name)
                        .font(.title3.weight(.semibold))
                    // The badge only appears when there's something to say.
                    if let tier {
                        Text(pet.mode.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tier.color.opacity(0.18)))
                            .foregroundColor(tier.color)
                    }
                }
                if let episode = episode {
                    Text("Day \(episode.durationDays) · \(episode.note)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    ResolutionDots(progress: store.resolutionProgress(for: episode))
                } else if let lastLog = store.lastOutputDate(for: pet.id) {
                    Text("All quiet · logged \(relativeDay(lastLog))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("All quiet. A first log starts their baseline")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        // Watch mode escalates the card itself — state lives with the pet.
        .card(tier.map { $0.color.opacity(0.10) } ?? DS.surface)
    }
}

/// Progress toward resolution: 3 consecutive normal outputs.
struct ResolutionDots: View {
    let progress: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < progress ? Tier.normal.color : Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
            Text("\(min(progress, 3)) of 3 normals to resolve")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - "Something's off" flow (W3)

struct SomethingsOffSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPetID: UUID?
    @State private var note = ""
    @State private var startedEpisode: Episode?

    var body: some View {
        NavigationStack {
            Group {
                if let episode = startedEpisode {
                    LookbackView(petID: episode.petID) {
                        dismiss()
                    }
                } else {
                    // Same bones as every other sheet: avatar row, chips,
                    // one pill field, one button.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if store.activePets.count > 1 {
                                SectionHeader(title: "Who's off?")
                                PetPickerRow(selection: $selectedPetID)
                            }
                            SectionHeader(title: "What's wrong?")
                            PillTextField(placeholder: "e.g. soft stool since this morning", text: $note)
                            Button {
                                guard let petID = selectedPetID else { return }
                                if let existing = store.activeEpisode(for: petID) {
                                    startedEpisode = existing
                                } else {
                                    startedEpisode = store.startEpisode(petID: petID, note: note.isEmpty ? "Something's off" : note)
                                }
                            } label: {
                                Text("Start watching")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedPetID == nil)
                        }
                        .padding()
                    }
                    .onAppear {
                        if selectedPetID == nil, store.activePets.count == 1 {
                            selectedPetID = store.activePets[0].id
                        }
                    }
                }
            }
            .navigationTitle(startedEpisode == nil ? "Something's off" : "48-hour lookback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
