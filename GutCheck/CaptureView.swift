import SwiftUI
import PhotosUI

/// W2 — Log an output. The camera tile opens the device camera directly; the
/// shot goes to the scorer and Scoop's own sandbox, never the Photos library
/// (the whole point is not having a camera roll full of poop). The simulator
/// has no camera, so it falls back to the system photo picker. With an API key
/// configured, Claude scores the photo and prefills the four axes; the owner
/// corrects. Without one, capture is fully manual.
struct CaptureSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    enum AIState: Equatable {
        case idle
        case scoring
        case scored(uncertain: [String])
        case notStool
        case failed
    }

    @State var petID: UUID?
    @State private var reading: StoolReading = .normal
    @State private var timing: LogTiming = .justNow
    @State private var pickedTime: Date = Date()
    @State private var note = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var aiState: AIState = .idle
    @State private var showMoreConsistency = false
    @State private var showMoreColors = false
    /// Coating and contents are "none" nine logs out of ten; they stay folded
    /// until the owner or the model says otherwise.
    @State private var showDetails = false
    @State private var savedResult: LogResult?
    @State private var showWatchPrompt = false
    @State private var lookbackPetID: UUID?

    private var liveTier: Tier {
        guard let petID = petID else { return .normal }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let liquidCount = store.data.events.filter {
            $0.petID == petID && $0.date >= dayAgo && $0.reading.consistency == .liquid
        }.count + (reading.consistency == .liquid ? 1 : 0)
        return triageTier(for: reading, liquidCountLast24h: liquidCount)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let lookbackPet = lookbackPetID {
                    LookbackView(petID: lookbackPet) { dismiss() }
                } else {
                    captureForm
                }
            }
            .navigationTitle(lookbackPetID == nil ? "Log a poop" : "48-hour lookback")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // One animal in the house: there is nobody else to pick.
                if petID == nil, store.activePets.count == 1 {
                    petID = store.activePets[0].id
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var captureForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Who: large avatars, not a text menu — in a multi-pet house,
                // logging to the wrong animal is the #1 silent data error.
                HStack(alignment: .top, spacing: 16) {
                    ForEach(store.activePets) { pet in
                        Button {
                            petID = pet.id
                        } label: {
                            VStack(spacing: 5) {
                                PetAvatar(pet: pet, size: 54)
                                    .overlay(
                                        Circle().stroke(petID == pet.id ? DS.brand : .clear, lineWidth: 2.5)
                                    )
                                Text(pet.name)
                                    .font(.caption.weight(petID == pet.id ? .bold : .regular))
                                    .foregroundColor(petID == pet.id ? DS.brand : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    TierBadge(tier: liveTier)
                }

                // Photo-first capture. Tap opens the camera itself, not the
                // photo picker: the shot lives only in Scoop's sandbox and is
                // never written to the Photos library. The simulator has no
                // camera, so it falls back to the library picker there.
                Button {
                    if CameraCapture.isAvailable {
                        showCamera = true
                    } else {
                        showLibrary = true
                    }
                } label: {
                    if let data = photoData, let image = UIImage(data: data) {
                        HStack(spacing: 12) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Photo attached")
                                    .font(.subheadline.weight(.semibold))
                                Text(photoSubtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if aiState == .scoring {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Snap a photo")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                Text(AIScorer.isConfigured
                                     ? "AI scores it, you confirm"
                                     : "Or score with the chips below")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
                    }
                }
                .buttonStyle(.plain)
                .fullScreenCover(isPresented: $showCamera) {
                    CameraCapture { data in
                        photoData = data
                        scorePhoto()
                    }
                    .ignoresSafeArea()
                }
                .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
                .onChange(of: photoItem) { item in
                    guard let item = item else { return }
                    Task { @MainActor in
                        photoData = try? await item.loadTransferable(type: Data.self)
                        scorePhoto()
                    }
                }

                axisSection(title: "Consistency", tier: reading.consistency.tier) {
                    // An ordered scale should look ordered: severity runs left
                    // to right, unlike the unordered chip sets below.
                    OrdinalScale(selection: $reading.consistency)
                    if showMoreConsistency || reading.consistency == .hard {
                        Chip(label: ConsistencyChoice.hard.label,
                             isSelected: reading.consistency == .hard,
                             tint: ConsistencyChoice.hard.tier.color) {
                            reading.consistency = .hard
                        }
                    } else {
                        Chip(label: "more…", isSelected: false, tint: .secondary) {
                            showMoreConsistency = true
                        }
                    }
                }

                axisSection(title: "Color", tier: reading.color.tier) {
                    chipWrap {
                        ForEach(StoolColor.primary) { color in
                            Chip(label: color.label,
                                 isSelected: reading.color == color,
                                 tint: color.tier.color,
                                 swatch: color.swatch) {
                                reading.color = color
                            }
                        }
                        if showMoreColors || StoolColor.secondary.contains(reading.color) {
                            ForEach(StoolColor.secondary) { color in
                                Chip(label: color.label,
                                     isSelected: reading.color == color,
                                     tint: color.tier.color,
                                     swatch: color.swatch) {
                                    reading.color = color
                                }
                            }
                        } else {
                            Chip(label: "more…", isSelected: false, tint: .secondary) {
                                showMoreColors = true
                            }
                        }
                    }
                }

                if showDetails || reading.coating != .none || reading.contents != .none {
                    axisSection(title: "Coating", tier: reading.coating.tier) {
                        chipWrap {
                            ForEach(Coating.allCases) { coating in
                                Chip(label: coating.label,
                                     isSelected: reading.coating == coating,
                                     tint: coating.tier.color) {
                                    reading.coating = coating
                                }
                            }
                        }
                    }

                    axisSection(title: "Contents", tier: reading.contents.tier) {
                        chipWrap {
                            ForEach(Contents.allCases) { contents in
                                Chip(label: contents.label,
                                     isSelected: reading.contents == contents,
                                     tint: contents.tier.color) {
                                    reading.contents = contents
                                }
                            }
                        }
                    }
                } else {
                    // The form is for correcting, not reading: two axes that
                    // are almost always "none" take one line until they aren't.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showDetails = true }
                    } label: {
                        HStack {
                            Text("Coating none · Contents none")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Change")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
                    }
                    .buttonStyle(.plain)
                }

                axisSection(title: "When?", tier: .normal) {
                    TimingPicker(timing: $timing, pickedTime: $pickedTime)
                }

                PillTextField(placeholder: "Note", text: $note)

                saveArea

                if AIScorer.isConfigured {
                    // The disclosure lives once, out of the hot path.
                    Text("Photos are sent to Anthropic for scoring only.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .confirmationDialog("Open watch mode?", isPresented: $showWatchPrompt, titleVisibility: .visible) {
            Button("Yes, start watching") {
                if let petID = petID {
                    store.startEpisode(petID: petID, note: "Abnormal output logged")
                    lookbackPetID = petID
                }
            }
            Button("Not now", role: .cancel) { dismiss() }
        } message: {
            Text("That log was abnormal. Watch mode tracks everything until it resolves.")
        }
    }

    /// Urgent findings break the layout (W2): the vet action becomes the primary
    /// button and the save is demoted to a text link.
    @ViewBuilder
    private var saveArea: some View {
        // Triage feedback repeated at the point of commitment — the top badge
        // is off-screen by the time the thumb reaches save.
        HStack(spacing: 8) {
            Text("Reads as")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TierBadge(tier: liveTier)
            Spacer()
        }
        // Saving with nobody selected used to be a silent no-op: tap, nothing.
        if petID == nil {
            Label("Pick who this is for at the top", systemImage: "arrow.up.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DS.brand)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if liveTier == .urgent {
            VStack(spacing: 12) {
                Label("This is one of the things vets want to know about promptly.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Tier.urgent.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Tier.urgent.color.opacity(0.12)))
                Button {
                    save()
                } label: {
                    Text("Save & prepare a vet summary")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tier.urgent.color)
                .disabled(petID == nil)
                Button("Just save the log") { save() }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .disabled(petID == nil)
            }
        } else {
            Button {
                save()
            } label: {
                Text("Looks right, save it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(liveTier == .normal ? Tier.normal.color : liveTier.color)
            .disabled(petID == nil)
        }
    }

    private var photoSubtitle: String {
        switch aiState {
        case .idle:
            return AIScorer.isConfigured ? "Tap to change" : "On the record. Score with the chips below"
        case .scoring:
            return "Scoring the photo…"
        case .scored(let uncertain) where uncertain.isEmpty:
            return "AI prefilled all four axes. Tap any chip to correct"
        case .scored(let uncertain):
            return "AI prefilled the axes. Double-check \(uncertain.joined(separator: " and "))"
        case .notStool:
            return "That doesn't look like a stool photo. Score with the chips below"
        case .failed:
            return "AI scoring didn't work this time. Score with the chips below"
        }
    }

    /// The model proposes, the owner disposes: scores prefill the chips but
    /// the human can override every axis before anything is saved.
    private func scorePhoto() {
        guard AIScorer.isConfigured, let data = photoData else { return }
        aiState = .scoring
        Task { @MainActor in
            do {
                let score = try await AIScorer.score(data)
                if score.isStool {
                    reading = score.reading
                    if score.reading.consistency == .hard { showMoreConsistency = true }
                    if StoolColor.secondary.contains(score.reading.color) { showMoreColors = true }
                    // A model that isn't sure about coating or contents
                    // unfolds them so the owner looks instead of assuming.
                    if score.uncertainAxes.contains(where: { $0 == "coating" || $0 == "contents" }) {
                        showDetails = true
                    }
                    aiState = .scored(uncertain: score.uncertainAxes)
                } else {
                    aiState = .notStool
                }
            } catch {
                aiState = .failed
            }
        }
    }

    private func save() {
        guard let petID = petID else { return }
        let filename = photoData.map { store.savePhoto($0) }
        let result = store.logOutput(petID: petID, reading: reading, note: note, photoFilename: filename, date: timing.resolve(pickedTime: pickedTime))
        savedResult = result
        if result.suggestWatch {
            showWatchPrompt = true
        } else {
            dismiss()
        }
    }

    private func axisSection<Content: View>(title: String, tier: Tier, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: title)
                if tier > .normal {
                    TierBadge(tier: tier)
                }
            }
            content()
        }
    }

    private func chipWrap<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        FlowLayout(spacing: 8) {
            content()
        }
    }
}

/// The five-point consistency scale as an ordered horizontal control —
/// severity is legible in the layout itself, left (fine) to right (bad).
struct OrdinalScale: View {
    @Binding var selection: ConsistencyChoice

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ConsistencyChoice.primary) { choice in
                let isSelected = selection == choice
                Button {
                    selection = choice
                } label: {
                    Text(choice.label)
                        .font(.footnote.weight(isSelected ? .bold : .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.rowRadius)
                                .fill(isSelected ? choice.tier.color.opacity(0.18) : DS.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.rowRadius)
                                .stroke(isSelected ? choice.tier.color : Color.clear, lineWidth: 1.5)
                        )
                        .foregroundColor(isSelected ? choice.tier.color : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping layout for chips (iOS 16+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Direct camera capture. Wraps UIImagePickerController in camera mode so the
/// shot is handed back as JPEG data and nothing is saved to the Photos library.
/// Output is normalized to portrait-up and capped at 2048px on the long edge:
/// enough detail for scoring, small enough to send and store.
struct CameraCapture: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = CameraCapture.jpegData(from: image) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }

    /// Redraws the image so orientation is baked into the pixels (camera shots
    /// carry it as metadata, which not every consumer honors) and downscales.
    static func jpegData(from image: UIImage, maxPixel: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxPixel / longest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
