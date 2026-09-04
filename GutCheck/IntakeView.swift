import SwiftUI

// MARK: - "Gave something" (food, treats, meds, supplements)

/// Log that an animal got something, by name. Meds and treats share one sheet
/// because they share one question: what went in, and when. A repeat is two
/// taps (chip, log); the first time, the item is created in place.
struct IntakeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State var petID: UUID?
    /// Pre-select an item (from the regimen list, say).
    var preselectedItemID: UUID? = nil

    @State private var selectedItemID: UUID?
    @State private var creatingNew = false
    @State private var newName = ""
    @State private var newKind: ItemKind = .treat
    @State private var newDose = ""
    @State private var newSchedule: Set<DoseSlot> = []
    @State private var newInterval: DoseInterval?
    @State private var amount = ""
    @State private var slot: DoseSlot?
    @State private var timing: LogTiming = .justNow
    @State private var pickedTime: Date = Date()
    /// Long-term doses get a real date: the injection was at the vet last
    /// Tuesday, not "yesterday".
    @State private var pickedDate: Date = Date()
    @State private var note = ""

    private var soloPet: Pet? {
        store.activePets.count == 1 ? store.activePets.first : nil
    }

    private var effectivePetID: UUID? { soloPet?.id ?? petID }

    private var selectedItem: Item? {
        selectedItemID.flatMap { store.item($0) }
    }

    /// Whether what's being logged is a long-term recurring dose.
    private var isRecurringDose: Bool {
        creatingNew ? (newKind.isRegimen && newInterval != nil) : (selectedItem?.interval != nil)
    }

    private var canSave: Bool {
        guard effectivePetID != nil else { return false }
        if creatingNew {
            return !newName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return selectedItemID != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A piece of banana today is a bad stool tomorrow. Name it now and the record can connect the two.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if soloPet == nil {
                        SectionHeader(title: "Who?")
                        PetPickerRow(selection: $petID)
                    }

                    SectionHeader(title: "What?")
                    whatSection

                    if let item = selectedItem, item.isScheduled, !creatingNew {
                        SectionHeader(title: "Which dose?")
                        FlowLayout(spacing: 8) {
                            ForEach(item.schedule) { option in
                                Chip(label: option.label, isSelected: slot == option, tint: .accentColor) {
                                    slot = option
                                }
                            }
                            Chip(label: "Extra dose", isSelected: slot == nil, tint: .accentColor) {
                                slot = nil
                            }
                        }
                    }

                    SectionHeader(title: "How much?")
                    PillTextField(placeholder: amountPlaceholder, text: $amount)

                    SectionHeader(title: "When?")
                    if isRecurringDose {
                        HStack {
                            Text("Given on")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            DatePicker("Given on", selection: $pickedDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    } else {
                        TimingPicker(timing: $timing, pickedTime: $pickedTime)
                    }

                    PillTextField(placeholder: "Note", text: $note)

                    Button {
                        save()
                    } label: {
                        Text("Log it")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
                .padding()
            }
            .navigationTitle("Food & meds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if petID == nil, store.activePets.count == 1 {
                    petID = store.activePets[0].id
                }
                if let preselectedItemID, selectedItemID == nil {
                    select(preselectedItemID)
                }
            }
        }
    }

    @ViewBuilder
    private var whatSection: some View {
        let recent = effectivePetID.map { store.recentItems(for: $0) }
            ?? store.data.items.filter { $0.isActive && $0.scope == .household }
        FlowLayout(spacing: 8) {
            ForEach(recent) { item in
                Chip(label: item.name, isSelected: selectedItemID == item.id && !creatingNew, tint: item.kind.tint) {
                    creatingNew = false
                    select(item.id)
                }
            }
            Chip(label: recent.isEmpty ? "Something new" : "+ Something new", isSelected: creatingNew, tint: .accentColor) {
                creatingNew = true
                selectedItemID = nil
                slot = nil
            }
        }
        if creatingNew {
            NewItemFields(name: $newName, kind: $newKind, dose: $newDose, schedule: $newSchedule, interval: $newInterval)
                .onChange(of: newDose) { _, value in
                    if amount.isEmpty || amount == newDose { amount = value }
                }
        }
    }

    private var amountPlaceholder: String {
        if let item = selectedItem, !item.dose.isEmpty { return item.dose }
        switch (creatingNew ? newKind : selectedItem?.kind) ?? .treat {
        case .med, .supplement: return "e.g. 250mg, 1 capsule"
        case .food: return "e.g. half a bowl"
        case .treat, .chew: return "e.g. a few bites"
        }
    }

    private func select(_ id: UUID) {
        selectedItemID = id
        guard let item = store.item(id) else { return }
        amount = item.dose
        slot = item.isScheduled ? DoseSlot.current() : nil
        if item.isScheduled, !item.schedule.contains(slot ?? .morning) {
            slot = item.schedule.first
        }
    }

    private func save() {
        guard let petID = effectivePetID else { return }
        let date = isRecurringDose ? min(pickedDate, Date()) : timing.resolve(pickedTime: pickedTime)
        var itemID = selectedItemID
        var doseSlot = slot
        if creatingNew {
            let interval = newKind.isRegimen ? newInterval : nil
            let schedule = newKind.isRegimen && interval == nil ? DoseSlot.allCases.filter { newSchedule.contains($0) } : []
            let item = Item(name: newName.trimmingCharacters(in: .whitespaces),
                            scope: newKind.defaultsToHousehold ? .household : .pet(petID),
                            kind: newKind,
                            firstIntroduced: date,
                            dose: newDose.trimmingCharacters(in: .whitespaces),
                            schedule: schedule,
                            interval: interval,
                            trackedSince: Date())
            store.addItem(item)
            itemID = item.id
            doseSlot = schedule.isEmpty ? nil : (schedule.contains(DoseSlot.current(at: date)) ? DoseSlot.current(at: date) : schedule.first)
            if !schedule.isEmpty || interval != nil {
                Task { await DoseReminders.shared.requestAuthorization() }
            }
        }
        guard let itemID else { return }
        store.logIntake(petID: petID, itemID: itemID, date: date,
                        amount: amount.trimmingCharacters(in: .whitespaces),
                        slot: doseSlot, note: note)
        dismiss()
    }
}

/// Horizontal avatar picker, shared by the sheets that need a "who".
struct PetPickerRow: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(store.activePets) { pet in
                let isSelected = selection == pet.id
                Button {
                    selection = pet.id
                } label: {
                    VStack(spacing: 5) {
                        PetAvatar(pet: pet, size: 54)
                            .overlay(Circle().stroke(isSelected ? DS.brand : .clear, lineWidth: 2.5))
                        Text(pet.name)
                            .font(.caption.weight(isSelected ? .bold : .regular))
                            .foregroundColor(isSelected ? DS.brand : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

/// The fields that define a new item, shared by the in-place create and the
/// full editor. Cadence only appears for meds and supplements: daily slots,
/// a long-term interval (monthly heartworm, a monthly injection), or as
/// needed.
struct NewItemFields: View {
    @Binding var name: String
    @Binding var kind: ItemKind
    @Binding var dose: String
    @Binding var schedule: Set<DoseSlot>
    @Binding var interval: DoseInterval?

    /// Which cadence family is picked. Daily and interval are exclusive.
    private enum Cadence: Equatable {
        case asNeeded
        case daily
        case interval
    }

    /// "Other…" reveals a count-and-unit stepper for cadences off the preset list.
    @State private var customInterval = false

    private var cadence: Cadence {
        if interval != nil { return .interval }
        return schedule.isEmpty ? .asNeeded : .daily
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PillTextField(placeholder: "Name — banana, metronidazole, CBD oil", text: $name)
            FlowLayout(spacing: 8) {
                ForEach(ItemKind.allCases) { option in
                    Chip(label: option.label, isSelected: kind == option, tint: option.tint) {
                        kind = option
                        if !option.isRegimen {
                            schedule = []
                            interval = nil
                        }
                    }
                }
            }
            if kind.isRegimen {
                PillTextField(placeholder: "Usual dose — 250mg, 1 tsp, 0.5ml", text: $dose)
                VStack(alignment: .leading, spacing: 6) {
                    Text("How often?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    FlowLayout(spacing: 8) {
                        Chip(label: "Every day", isSelected: cadence == .daily, tint: .accentColor) {
                            interval = nil
                            customInterval = false
                            if schedule.isEmpty { schedule = [.morning] }
                        }
                        ForEach(DoseInterval.presets, id: \.self) { preset in
                            Chip(label: preset.label, isSelected: interval == preset && !customInterval, tint: .accentColor) {
                                schedule = []
                                interval = preset
                                customInterval = false
                            }
                        }
                        Chip(label: "Other…", isSelected: customInterval, tint: .accentColor) {
                            schedule = []
                            customInterval = true
                            if interval.map({ DoseInterval.presets.contains($0) }) ?? true {
                                interval = DoseInterval(count: 2, unit: .day)
                            }
                        }
                        Chip(label: "As needed", isSelected: cadence == .asNeeded, tint: .accentColor) {
                            schedule = []
                            interval = nil
                            customInterval = false
                        }
                    }
                    if cadence == .daily {
                        HStack(spacing: 8) {
                            ForEach(DoseSlot.allCases) { slot in
                                Chip(label: "\(slot.label) · \(slot.hourLabel)", isSelected: schedule.contains(slot), tint: .accentColor) {
                                    if schedule.contains(slot) {
                                        // Keep at least one slot; "no slots" is the As-needed chip.
                                        if schedule.count > 1 { schedule.remove(slot) }
                                    } else {
                                        schedule.insert(slot)
                                    }
                                }
                            }
                        }
                    }
                    if customInterval, let current = interval {
                        HStack(spacing: 10) {
                            Stepper(value: Binding(
                                get: { current.count },
                                set: { interval = DoseInterval(count: $0, unit: current.unit) }
                            ), in: 1...52) {
                                Text("Every \(current.count)")
                                    .font(.subheadline)
                            }
                            .fixedSize()
                            ForEach(DoseInterval.Unit.allCases) { unit in
                                Chip(label: unit.label(current.count), isSelected: current.unit == unit, tint: .accentColor) {
                                    interval = DoseInterval(count: current.count, unit: unit)
                                }
                            }
                        }
                    }
                    Text(cadenceHint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
        .onAppear {
            if let interval, !DoseInterval.presets.contains(interval) { customInterval = true }
        }
    }

    private var cadenceHint: String {
        switch cadence {
        case .asNeeded: return "Logged as it happens; no reminders."
        case .daily: return "You'll get a reminder at each time, and missed doses show up in the record."
        case .interval: return "The next dose is counted from the last one you log. You'll get a reminder on the day, and a nudge each morning it's late."
        }
    }
}

// MARK: - Item editor

/// Create or edit one item for one animal. Stopping keeps it; deleting is
/// for mistakes.
struct ItemEditSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let petID: UUID
    private let existing: Item?

    @State private var name: String
    @State private var kind: ItemKind
    @State private var dose: String
    @State private var schedule: Set<DoseSlot>
    @State private var interval: DoseInterval?
    @State private var started: Date
    /// For a new long-term med: when the last dose went in, so the next due
    /// date is right from the first screen. Nil = not given yet.
    @State private var lastGiven: Date? = Date()
    @State private var showDeleteConfirm = false

    init(petID: UUID, item: Item? = nil, defaultKind: ItemKind = .med) {
        self.petID = petID
        self.existing = item
        _name = State(initialValue: item?.name ?? "")
        _kind = State(initialValue: item?.kind ?? defaultKind)
        _dose = State(initialValue: item?.dose ?? "")
        _schedule = State(initialValue: Set(item?.schedule ?? []))
        _interval = State(initialValue: item?.interval)
        _started = State(initialValue: item?.firstIntroduced ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NewItemFields(name: $name, kind: $kind, dose: $dose, schedule: $schedule, interval: $interval)

                    SectionHeader(title: existing == nil ? "Started" : "Started on")
                    DatePicker("Started", selection: $started, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    if existing == nil, kind.isRegimen, interval == nil, !schedule.isEmpty {
                        Text("Backdating the start doesn't invent missed doses — tracking begins today.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if existing == nil, kind.isRegimen, let interval {
                        SectionHeader(title: "Last dose")
                        lastDoseFields(interval: interval)
                    }

                    Button {
                        save()
                    } label: {
                        Text(existing == nil ? "Add it" : "Save")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let existing {
                        if existing.isActive {
                            Button {
                                store.stopItem(id: existing.id)
                                dismiss()
                            } label: {
                                Text("Stopped giving this")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                var restarted = existing
                                restarted.stopped = nil
                                restarted.trackedSince = Date()
                                store.updateItem(restarted)
                                dismiss()
                            } label: {
                                Text("Started again")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete, including every dose logged")
                                .font(.footnote)
                                .frame(maxWidth: .infinity)
                        }
                        .confirmationDialog("Delete \(existing.name)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                            Button("Delete it and its history", role: .destructive) {
                                store.removeItem(id: existing.id)
                                dismiss()
                            }
                            Button("Keep", role: .cancel) {}
                        } message: {
                            Text("Use “Stopped giving this” to end a course and keep the record.")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(existing == nil ? "New item" : existing!.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// "Given already, on this date" or "not yet" — the one fact a monthly
    /// med needs before its next due date means anything.
    @ViewBuilder
    private func lastDoseFields(interval: DoseInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Chip(label: "Already given", isSelected: lastGiven != nil, tint: .accentColor) {
                    if lastGiven == nil { lastGiven = Date() }
                }
                Chip(label: "Not yet", isSelected: lastGiven == nil, tint: .accentColor) {
                    lastGiven = nil
                }
            }
            if let given = lastGiven {
                HStack {
                    Text("Last given on")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    DatePicker("Last given", selection: Binding(
                        get: { given },
                        set: { lastGiven = $0 }
                    ), in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                Text("That dose goes in the record, and the next one is due \(shortDate(interval.next(after: given))).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("The first dose will show as due today.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func save() {
        let cadenceInterval = kind.isRegimen ? interval : nil
        let orderedSchedule = kind.isRegimen && cadenceInterval == nil ? DoseSlot.allCases.filter { schedule.contains($0) } : []
        let trimmedDose = dose.trimmingCharacters(in: .whitespaces)
        if var item = existing {
            let wasScheduled = item.isScheduled
            item.name = name.trimmingCharacters(in: .whitespaces)
            item.kind = kind
            item.dose = trimmedDose
            item.schedule = orderedSchedule
            let wasRecurring = item.isRecurring
            item.interval = cadenceInterval
            item.firstIntroduced = started
            if !wasScheduled, !orderedSchedule.isEmpty { item.trackedSince = Date() }
            // A cadence added to an existing item starts counting today; the
            // months before it was tracked are not months overdue.
            if !wasRecurring, cadenceInterval != nil { item.trackedSince = Date() }
            store.updateItem(item)
        } else {
            let item = Item(name: name.trimmingCharacters(in: .whitespaces),
                            scope: kind.defaultsToHousehold ? .household : .pet(petID),
                            kind: kind,
                            firstIntroduced: started,
                            dose: trimmedDose,
                            schedule: orderedSchedule,
                            interval: cadenceInterval,
                            trackedSince: Date())
            store.addItem(item)
            // The last dose of a long-term med is a real event: it anchors
            // the next due date and belongs in the timeline.
            if cadenceInterval != nil, let given = lastGiven {
                let stamp = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: given) ?? given
                store.logIntake(petID: petID, itemID: item.id, date: min(stamp, Date()), amount: trimmedDose)
            }
        }
        if !orderedSchedule.isEmpty || cadenceInterval != nil {
            Task { await DoseReminders.shared.requestAuthorization() }
        }
        dismiss()
    }
}

// MARK: - Regimen (the pet's meds & supplements)

struct RegimenSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reminders = DoseReminders.shared
    let petID: UUID

    @State private var editing: Item?
    @State private var adding = false

    var body: some View {
        let pet = store.pet(petID)
        let active = store.regimen(for: petID)
        let stopped = store.items(for: petID).filter { $0.kind.isRegimen && !$0.isActive }
            .sorted { ($0.stopped ?? .distantPast) > ($1.stopped ?? .distantPast) }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(pet?.name ?? "Their")'s meds and supplements. Scheduled ones get a checklist and a reminder; the rest are logged as they happen.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if reminders.authorization == .denied, !active.filter(\.isScheduled).isEmpty {
                        Label("Reminders are off in Settings → Notifications → Scoop. The checklist still works.", systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundColor(Tier.monitor.color)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(Tier.monitor.color.opacity(0.08)))
                    }

                    if active.isEmpty {
                        Text("Nothing yet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        SectionHeader(title: "Current")
                        ForEach(active) { item in
                            Button { editing = item } label: {
                                RegimenRow(item: item, intervalState: store.intervalState(petID: petID, item: item))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        adding = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add a med or supplement")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: DS.radius)
                                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        )
                    }
                    .buttonStyle(.plain)

                    if !stopped.isEmpty {
                        SectionHeader(title: "Stopped")
                        ForEach(stopped) { item in
                            Button { editing = item } label: { RegimenRow(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("\(pet?.name ?? "")'s meds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { item in
                ItemEditSheet(petID: petID, item: item)
            }
            .sheet(isPresented: $adding) {
                ItemEditSheet(petID: petID)
            }
        }
    }
}

struct RegimenRow: View {
    let item: Item
    /// Where a long-term med stands; nil for daily and as-needed items.
    var intervalState: IntervalDoseState? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundColor(item.isActive ? item.kind.tint : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name + (item.dose.isEmpty ? "" : " · \(item.dose)"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
    }

    private var subtitle: String {
        if let stopped = item.stopped {
            return "Stopped \(relativeDay(stopped)) · started \(shortDate(item.firstIntroduced))"
        }
        if let state = intervalState {
            let last = state.last.map { "last \(shortDate($0.date))" } ?? "none logged yet"
            return "\(item.cadenceLabel) · \(last) · \(state.dueLabel.lowercased())"
        }
        return "\(item.cadenceLabel) · since \(shortDate(item.firstIntroduced))"
    }
}

// MARK: - Today's checklist

/// Per-item ticks for today, grouped by slot. One tap gives; tapping a given
/// dose again clears it. Long-press to record a deliberate skip.
struct DoseChecklist: View {
    @EnvironmentObject var store: AppStore
    let petID: UUID
    var day: Date = Date()

    var body: some View {
        let slots = DoseSlot.allCases.filter { !store.scheduledItems(for: petID, slot: $0).isEmpty }
        if !slots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slots) { slot in
                    slotBlock(slot)
                }
                if let missedYesterday = missedYesterdayLine {
                    Text(missedYesterday)
                        .font(.caption2)
                        .foregroundColor(Tier.monitor.color)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.radius).fill(DS.surface))
        }
    }

    @ViewBuilder
    private func slotBlock(_ slot: DoseSlot) -> some View {
        let items = store.scheduledItems(for: petID, slot: slot)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: slot.symbol)
                    .font(.caption)
                Text("\(slot.label) · \(slot.hourLabel)")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let summary = store.slotSummary(petID: petID, slot: slot, day: day) {
                    Text(summaryLabel(summary))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(summaryColor(summary))
                }
            }
            .foregroundColor(.secondary)
            ForEach(items) { item in
                let state = store.doseState(petID: petID, item: item, slot: slot, day: day)
                Button {
                    store.setDose(petID: petID, item: item, slot: slot, day: day, status: state.isLogged ? nil : .given)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: checkSymbol(state))
                            .font(.title3)
                            .foregroundColor(checkColor(state))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name + (item.dose.isEmpty ? "" : " · \(item.dose)"))
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .strikethrough(isSkipped(state), color: .secondary)
                            if let detail = stateDetail(state) {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !isSkipped(state) {
                        Button {
                            store.setDose(petID: petID, item: item, slot: slot, day: day, status: .skipped)
                        } label: {
                            Label("Skipped on purpose", systemImage: "minus.circle")
                        }
                    }
                    if state.isLogged {
                        Button(role: .destructive) {
                            store.setDose(petID: petID, item: item, slot: slot, day: day, status: nil)
                        } label: {
                            Label("Clear", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
        }
    }

    private var missedYesterdayLine: String? {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: day)) else { return nil }
        let missed = store.missedDoses(for: petID, from: yesterday, to: day)
        guard !missed.isEmpty else { return nil }
        let names = missed.map { "\($0.item.name) (\($0.slot.label.lowercased()))" }
        return "Missed yesterday: " + names.joined(separator: ", ")
    }

    private func isSkipped(_ state: DoseState) -> Bool {
        if case .skipped = state { return true }
        return false
    }

    private func checkSymbol(_ state: DoseState) -> String {
        switch state {
        case .given: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .due, .missed: return "circle"
        case .upcoming: return "circle.dotted"
        }
    }

    private func checkColor(_ state: DoseState) -> Color {
        switch state {
        case .given: return Tier.normal.color
        case .skipped: return .secondary
        case .due, .missed: return Tier.monitor.color
        case .upcoming: return .secondary
        }
    }

    private func stateDetail(_ state: DoseState) -> String? {
        switch state {
        case .given(let intake): return "Given \(timeOnly(intake.date))"
        case .skipped: return "Skipped"
        case .due: return "Due"
        case .missed: return "Missed"
        case .upcoming: return nil
        }
    }

    private func summaryLabel(_ summary: AppStore.SlotSummary) -> String {
        if summary.isComplete { return "Done" }
        switch summary.pending {
        case .due: return "\(summary.given) of \(summary.total)"
        case .missed: return "Missed"
        default: return summary.given > 0 ? "\(summary.given) of \(summary.total)" : "Later"
        }
    }

    private func summaryColor(_ summary: AppStore.SlotSummary) -> Color {
        if summary.isComplete { return Tier.normal.color }
        if case .due = summary.pending { return Tier.monitor.color }
        if case .missed = summary.pending { return Tier.concern.color }
        return .secondary
    }
}

/// The long-term meds: one row each with the next due date and a one-tap
/// "Given". Tapping a dose given today again clears it. Long-press to log
/// it on another day (the injection was at the vet last Tuesday).
struct IntervalChecklist: View {
    @EnvironmentObject var store: AppStore
    let petID: UUID

    @State private var backdating: Item?

    var body: some View {
        let dues = store.intervalDues(for: petID)
        if !dues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.caption)
                    Text("Long-term")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundColor(.secondary)
                ForEach(dues) { due in
                    row(due)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.radius).fill(DS.surface))
            .sheet(item: $backdating) { item in
                IntakeSheet(petID: petID, preselectedItemID: item.id)
            }
        }
    }

    @ViewBuilder
    private func row(_ due: AppStore.IntervalDue) -> some View {
        let item = due.item
        let state = due.state
        Button {
            store.setIntervalDose(petID: petID, item: item, status: state.isLogged ? nil : .given)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(state))
                    .font(.title3)
                    .foregroundColor(color(state))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name + (item.dose.isEmpty ? "" : " · \(item.dose)"))
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(detail(state))
                        .font(.caption2)
                        .foregroundColor(state.isDue && !state.isLogged ? color(state) : .secondary)
                }
                Spacer()
                if !state.isLogged {
                    Text("Given")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(color(state).opacity(0.14)))
                        .foregroundColor(color(state))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                backdating = item
            } label: {
                Label("Given on another day…", systemImage: "calendar")
            }
            if !state.isLogged {
                Button {
                    store.setIntervalDose(petID: petID, item: item, status: .skipped)
                } label: {
                    Label("Skipped on purpose", systemImage: "minus.circle")
                }
            }
            if state.isLogged {
                Button(role: .destructive) {
                    store.setIntervalDose(petID: petID, item: item, status: nil)
                } label: {
                    Label("Clear", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private func detail(_ state: IntervalDoseState) -> String {
        if let given = state.givenToday { return "Given \(timeOnly(given.date)) · next \(shortDate(state.nextDue))" }
        var parts = [state.dueLabel]
        if let last = state.last {
            parts.append(last.status == .skipped ? "skipped \(shortDate(last.date))" : "last \(shortDate(last.date))")
        }
        return parts.joined(separator: " · ")
    }

    private func symbol(_ state: IntervalDoseState) -> String {
        if state.isLogged { return "checkmark.circle.fill" }
        return state.isDue ? "circle" : "circle.dotted"
    }

    private func color(_ state: IntervalDoseState) -> Color {
        if state.isLogged { return Tier.normal.color }
        if state.isOverdue { return Tier.concern.color }
        if state.isDue { return Tier.monitor.color }
        return .secondary
    }
}

/// One-tap pills for the home screen: "Morning ✓ · Evening due", plus any
/// long-term med that's due, late, or coming up in the next few days.
/// Tapping an incomplete slot gives everything in it; tapping a complete one
/// clears it (the mis-tap must be undoable in the same place).
struct DoseStrip: View {
    @EnvironmentObject var store: AppStore
    let petID: UUID

    /// A long-term med shows on the home screen this many days ahead —
    /// enough notice to order the refill, not so much it becomes noise.
    private let headsUpDays = 3

    var body: some View {
        let summaries = DoseSlot.allCases.compactMap { store.slotSummary(petID: petID, slot: $0) }
        let dues = store.intervalDues(for: petID).filter { $0.state.isLogged || $0.state.daysUntilDue <= headsUpDays }
        if !summaries.isEmpty || !dues.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(summaries, id: \.slot) { summary in
                    Button {
                        if summary.isComplete {
                            store.clearSlot(petID: petID, slot: summary.slot)
                        } else {
                            store.giveSlot(petID: petID, slot: summary.slot)
                        }
                    } label: {
                        pill(symbol: summary.isComplete ? "checkmark.circle.fill" : summary.slot.symbol,
                             text: label(summary), color: color(summary))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(dues) { due in
                    Button {
                        store.setIntervalDose(petID: petID, item: due.item, status: due.state.isLogged ? nil : .given)
                    } label: {
                        pill(symbol: due.state.isLogged ? "checkmark.circle.fill" : "calendar.badge.clock",
                             text: label(due), color: color(due.state))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pill(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundColor(color)
    }

    private func label(_ due: AppStore.IntervalDue) -> String {
        let name = due.item.name
        if due.state.isLogged { return "\(name) given" }
        let days = due.state.daysUntilDue
        if days == 0 { return "\(name) due" }
        if days == 1 { return "\(name) tomorrow" }
        if days > 0 { return "\(name) in \(days) days" }
        return "\(name) \(-days)d overdue"
    }

    private func color(_ state: IntervalDoseState) -> Color {
        if state.isLogged { return Tier.normal.color }
        if state.isOverdue { return Tier.concern.color }
        if state.isDue { return Tier.monitor.color }
        return .secondary
    }

    private func label(_ summary: AppStore.SlotSummary) -> String {
        if summary.isComplete { return "\(summary.slot.label) given" }
        switch summary.pending {
        case .due: return summary.given > 0 ? "\(summary.slot.label) \(summary.given) of \(summary.total)" : "\(summary.slot.label) due"
        case .missed: return "\(summary.slot.label) missed"
        default: return "\(summary.slot.label) \(summary.slot.hourLabel)"
        }
    }

    private func color(_ summary: AppStore.SlotSummary) -> Color {
        if summary.isComplete { return Tier.normal.color }
        if case .due = summary.pending { return Tier.monitor.color }
        if case .missed = summary.pending { return Tier.concern.color }
        return .secondary
    }
}

// MARK: - Timeline row

struct IntakeRow: View {
    @EnvironmentObject var store: AppStore
    let intake: IntakeEvent

    var body: some View {
        let item = store.item(intake.itemID)
        let kind = item?.kind ?? .treat
        HStack(spacing: 10) {
            Image(systemName: intake.status == .skipped ? "minus.circle" : kind.symbol)
                .foregroundColor(intake.status == .skipped ? .secondary : kind.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(item))
                    .font(.subheadline)
                    .strikethrough(intake.status == .skipped, color: .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(shortDateTime(intake.date))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
    }

    private func title(_ item: Item?) -> String {
        let name = item?.name ?? "Unknown item"
        return intake.amount.isEmpty ? name : "\(name) · \(intake.amount)"
    }

    private var subtitle: String {
        let item = store.item(intake.itemID)
        var parts: [String] = []
        if intake.status == .skipped { parts.append("Skipped") }
        if let slot = intake.slot {
            parts.append("\(slot.label) dose")
        } else if let interval = item?.interval {
            parts.append(interval.doseLabel)
        } else if item?.kind.isRegimen == true {
            parts.append("Extra dose")
        }
        if !intake.note.isEmpty { parts.append("“\(intake.note)”") }
        return parts.isEmpty ? (item?.kind.label ?? "") : parts.joined(separator: " · ")
    }
}

// MARK: - Small helpers

extension ItemKind {
    var tint: Color {
        switch self {
        case .med: return Tier.concern.color
        case .supplement: return Tier.normal.color
        case .food: return DS.brand
        case .treat: return Color(red: 0.48, green: 0.35, blue: 0.72)
        case .chew: return Color(red: 0.48, green: 0.35, blue: 0.72)
        }
    }
}

extension DoseSlot {
    /// "7am" / "7pm"
    var hourLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        return formatter.string(from: dueDate(on: Date())).lowercased()
    }
}

func timeOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
