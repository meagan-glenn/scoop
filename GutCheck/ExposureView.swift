import SwiftUI

/// Log a cause-side input the moment it happens: a med change, a stressful
/// event, an intake deviation. One tap each for what, who, and done.
struct ExposureSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ExposureKind?
    @State private var petID: UUID?
    @State private var wholeHousehold = false
    @State private var timing: LogTiming = .justNow
    @State private var pickedTime: Date = Date()
    @State private var note = ""

    private let medKinds: [ExposureKind] = [.medStarted, .medChanged]
    private let stressKinds: [ExposureKind] = [.travelBoarding, .houseGuests, .stressfulEvent]
    private let intakeKinds: [ExposureKind] = [.foundOutside, .tableFood, .newChew]

    /// With one animal there's no "who" to ask — everything is theirs.
    private var soloPet: Pet? {
        store.activePets.count == 1 ? store.activePets.first : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Meds and stress change outputs too. Log it now, and the lookback remembers so you don't have to.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    kindGroup(title: "Medication", kinds: medKinds)
                    kindGroup(title: "Stress & routine", kinds: stressKinds)
                    kindGroup(title: "Intake", kinds: intakeKinds)

                    if soloPet == nil {
                        SectionHeader(title: "Who?")
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(store.activePets) { pet in
                                let isSelected = petID == pet.id && !wholeHousehold
                                Button {
                                    petID = pet.id
                                    wholeHousehold = false
                                } label: {
                                    VStack(spacing: 5) {
                                        PetAvatar(pet: pet, size: 54)
                                            .overlay(
                                                Circle().stroke(isSelected ? DS.brand : .clear, lineWidth: 2.5)
                                            )
                                        Text(pet.name)
                                            .font(.caption.weight(isSelected ? .bold : .regular))
                                            .foregroundColor(isSelected ? DS.brand : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        Chip(label: "Whole household", isSelected: wholeHousehold, tint: .accentColor) {
                            wholeHousehold = true
                            petID = nil
                        }
                    }

                    SectionHeader(title: "When?")
                    TimingPicker(timing: $timing, pickedTime: $pickedTime)

                    PillTextField(placeholder: "Note", text: $note)

                    Button {
                        guard let kind = kind else { return }
                        let target = soloPet?.id ?? (wholeHousehold ? nil : petID)
                        store.logExposure(kind: kind, petID: target, note: note, date: timing.resolve(pickedTime: pickedTime))
                        dismiss()
                    } label: {
                        Text("Log it")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(kind == nil || (soloPet == nil && !wholeHousehold && petID == nil))
                }
                .padding()
            }
            .navigationTitle("Meds & stress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func kindGroup(title: String, kinds: [ExposureKind]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            FlowLayout(spacing: 8) {
                ForEach(kinds) { option in
                    Chip(label: option.label, isSelected: kind == option, tint: .accentColor) {
                        kind = option
                        // Stress usually hits everyone; meds hit one animal.
                        if option.defaultsToHousehold && petID == nil {
                            wholeHousehold = true
                        }
                    }
                }
            }
        }
    }
}

/// A single exposure row, shared by lookback and episode timeline.
struct ExposureRow: View {
    @EnvironmentObject var store: AppStore
    let exposure: ExposureEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: exposure.kind.symbol)
                .foregroundColor(exposure.kind.isMedication ? Tier.concern.color : Color(red: 0.48, green: 0.35, blue: 0.72))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(exposure.kind.label + (exposure.note.isEmpty ? "" : " · \(exposure.note)"))
                    .font(.subheadline)
                Text("\(subject) · \(relativeDay(exposure.date))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
    }

    private var subject: String {
        if let petID = exposure.petID {
            return store.pet(petID)?.name ?? "Unknown"
        }
        return "Whole household"
    }
}
