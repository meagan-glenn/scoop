import SwiftUI

/// W4 — The 48-hour lookback. Shown immediately on watch-mode entry or an
/// abnormal log: everything in the window, then "anything we missed?" chips.
struct LookbackView: View {
    @EnvironmentObject var store: AppStore
    let petID: UUID
    let onDone: () -> Void

    // Quick-add chips create real exposure events; toggling off removes them.
    @State private var addedExposures: [ExposureKind: UUID] = [:]

    private let quickAdds: [ExposureKind] = [
        .foundOutside, .tableFood, .newChew, .medChanged, .travelBoarding, .stressfulEvent,
    ]

    var body: some View {
        let lookback = store.lookback(petID: petID)
        let petName = store.pet(petID)?.name ?? "them"

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Stool reflects intake from 12 to 36 hours ago. Here's everything from \(petName)'s window.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if !lookback.newItems.isEmpty {
                    SectionHeader(title: "New in the last 2 weeks")
                    ForEach(lookback.newItems) { item in
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(Tier.monitor.color)
                            VStack(alignment: .leading) {
                                Text(item.name).font(.subheadline.weight(.semibold))
                                Text("\(item.kind) · introduced \(relativeDay(item.firstIntroduced))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Tier.monitor.color.opacity(0.08)))
                    }
                }

                if !lookback.crossFeeds.isEmpty {
                    SectionHeader(title: "Cross-feeding")
                    ForEach(lookback.crossFeeds) { feed in
                        HStack {
                            Image(systemName: "fork.knife.circle.fill")
                                .foregroundColor(Tier.concern.color)
                            Text("\(store.pet(feed.eaterID)?.name ?? "?") ate \(store.pet(feed.foodOwnerID)?.name ?? "?")'s food (\(feed.amount)) · \(relativeDay(feed.date))")
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
                    }
                }

                if !lookback.exposures.isEmpty {
                    SectionHeader(title: "Meds, stress & intake (last 7 days)")
                    ForEach(lookback.exposures) { exposure in
                        ExposureRow(exposure: exposure)
                    }
                }

                if !lookback.outputs.isEmpty {
                    SectionHeader(title: "Outputs in the window")
                    ForEach(lookback.outputs) { event in
                        OutputRow(event: event)
                    }
                }

                SectionHeader(title: "Anything we missed?")
                FlowLayout(spacing: 8) {
                    ForEach(quickAdds) { kind in
                        let existing = addedExposures[kind]
                        Chip(label: kind.label, isSelected: existing != nil, tint: .accentColor) {
                            if let id = existing {
                                store.removeExposure(id: id)
                                addedExposures[kind] = nil
                            } else {
                                let exposure = store.logExposure(kind: kind, petID: kind.defaultsToHousehold ? nil : petID)
                                addedExposures[kind] = exposure.id
                            }
                        }
                    }
                }

                Button {
                    onDone()
                } label: {
                    Text("Done, start watching")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

struct OutputRow: View {
    @EnvironmentObject var store: AppStore
    let event: OutputEvent
    @State private var showPhoto = false
    /// Small, decoded once. The full-size image only loads for the sheet.
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(event.tier.color)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.reading.consistency.label)
                        .font(.subheadline.weight(.semibold))
                    Text("(vet score \(event.reading.consistency.vetScore))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    TierBadge(tier: event.tier)
                }
                Text(readingSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(shortDateTime(event.date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let image = thumbnail {
                // Blurred until deliberately tapped — nobody wants this photo
                // ambushing them mid-scroll.
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .blur(radius: 10, opaque: true)
                    Image(systemName: "eye.slash.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { showPhoto = true }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(DS.surface))
        .task(id: event.photoFilename) {
            thumbnail = await loadImage(maxPixel: 132)
        }
        .sheet(isPresented: $showPhoto) {
            PhotoSheetLoader(load: { await loadImage(maxPixel: nil) })
        }
    }

    /// Reads and decodes off the main thread; `maxPixel` downsamples for the
    /// row so a 12-megapixel camera photo isn't decoded (and blurred) full size
    /// inside a list.
    private func loadImage(maxPixel: CGFloat?) async -> UIImage? {
        guard let filename = event.photoFilename else { return nil }
        let url = store.photoURL(filename)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
            guard let maxPixel else { return image }
            let scale = min(1, maxPixel / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return await image.byPreparingThumbnail(ofSize: size) ?? image
        }.value
    }

    private var readingSummary: String {
        var parts = [event.reading.color.label]
        if event.reading.coating != Coating.none { parts.append(event.reading.coating.label) }
        if event.reading.contents != Contents.none { parts.append(event.reading.contents.label) }
        if !event.note.isEmpty { parts.append("“\(event.note)”") }
        return parts.joined(separator: " · ")
    }
}

/// The sheet body can't await; this loads the full image, then shows it.
private struct PhotoSheetLoader: View {
    let load: () async -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomablePhotoView(image: image)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
        }
        .task { image = await load() }
    }
}

/// Full-screen photo with pinch-to-zoom — the second-opinion flow means a
/// partner is judging this image on their own phone.
///
/// Opens fitted to the screen and zooms from there. (A SwiftUI two-axis
/// ScrollView gives a resizable image its native pixel size, which for a
/// camera photo meant thousands of points of scrolling and no zoom at all.)
struct ZoomablePhotoView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            ZoomableImage(image: image)
                .ignoresSafeArea()
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

/// UIScrollView does zoom-and-pan correctly out of the box; SwiftUI still
/// doesn't. Fit on open, pinch to 4x, double-tap to toggle.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.maximumZoomScale = 4

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Layout happens after SwiftUI sizes the view; fit once bounds exist.
        DispatchQueue.main.async {
            context.coordinator.fit(in: scrollView, imageSize: image.size)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        private var fittedForBounds: CGSize = .zero

        func fit(in scrollView: UIScrollView, imageSize: CGSize) {
            guard let imageView, scrollView.bounds.size != .zero,
                  scrollView.bounds.size != fittedForBounds, imageSize.width > 0, imageSize.height > 0 else { return }
            fittedForBounds = scrollView.bounds.size
            imageView.frame = CGRect(origin: .zero, size: imageSize)
            scrollView.contentSize = imageSize
            let scale = min(scrollView.bounds.width / imageSize.width, scrollView.bounds.height / imageSize.height)
            scrollView.minimumZoomScale = scale
            scrollView.zoomScale = scale
            center(scrollView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(scrollView) }

        /// Keep a smaller-than-viewport image centered instead of top-left.
        private func center(_ scrollView: UIScrollView) {
            let dx = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let dy = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 3)
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - Cross-feeding (one tap: who ate whose, roughly how much)

struct CrossFeedSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var eaterID: UUID?
    @State private var ownerID: UUID?
    @State private var amount = "a few bites"

    private let amounts = ["a few bites", "half the bowl", "the whole bowl", "unknown"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Who ate…") {
                    Picker("Eater", selection: $eaterID) {
                        Text("Pick a pet").tag(UUID?.none)
                        ForEach(store.activePets) { pet in
                            Text("\(pet.avatar) \(pet.name)").tag(Optional(pet.id))
                        }
                    }
                }
                Section("…whose food?") {
                    Picker("Food owner", selection: $ownerID) {
                        Text("Pick a pet").tag(UUID?.none)
                        ForEach(store.activePets) { pet in
                            Text("\(pet.avatar) \(pet.name)").tag(Optional(pet.id))
                        }
                    }
                }
                Section("How much?") {
                    FlowLayout(spacing: 8) {
                        ForEach(amounts, id: \.self) { option in
                            Chip(label: option, isSelected: amount == option, tint: .accentColor) {
                                amount = option
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button {
                        if let eater = eaterID, let owner = ownerID {
                            store.logCrossFeed(eaterID: eater, foodOwnerID: owner, amount: amount)
                            dismiss()
                        }
                    } label: {
                        Text("Log it")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(eaterID == nil || ownerID == nil || eaterID == ownerID)
                }
            }
            .navigationTitle("Food theft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
