import SwiftUI

/// Design system: one brand accent, warm surfaces, two radii, rounded type.
enum DS {
    /// Cards and hero containers.
    static let radius: CGFloat = 16
    /// Timeline rows and other list-like elements.
    static let rowRadius: CGFloat = 12

    /// Brand indigo — deliberately distinct from every tier color, so the
    /// interface never reads "alarmed" by default.
    static let brand = Color(red: 0.44, green: 0.42, blue: 0.90)

    /// Warm card surface instead of flat system gray; adapts to dark mode.
    static let surface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.125, blue: 0.15, alpha: 1)
            : UIColor(red: 0.965, green: 0.955, blue: 0.935, alpha: 1)
    })
}

/// Standard card container: one padding, one radius, one surface.
struct CardStyle: ViewModifier {
    var fill: Color = DS.surface

    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.radius).fill(fill))
    }
}

extension View {
    func card(_ fill: Color = DS.surface) -> some View {
        modifier(CardStyle(fill: fill))
    }
}

extension Tier {
    var color: Color {
        switch self {
        case .normal: return Color(red: 0.22, green: 0.62, blue: 0.41)
        case .monitor: return Color(red: 0.85, green: 0.65, blue: 0.13)
        case .concern: return Color(red: 0.87, green: 0.44, blue: 0.15)
        case .urgent: return Color(red: 0.78, green: 0.16, blue: 0.16)
        }
    }

    /// Shape alongside color — triage must survive color-blindness and sunlight.
    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .monitor: return "eye.fill"
        case .concern: return "exclamationmark.triangle.fill"
        case .urgent: return "cross.circle.fill"
        }
    }
}

extension StoolColor {
    /// Literal color for the chip swatch — the axis is color, so show it.
    var swatch: Color {
        switch self {
        case .brown: return Color(red: 0.45, green: 0.30, blue: 0.16)
        case .green: return Color(red: 0.40, green: 0.55, blue: 0.25)
        case .yellowOrange: return Color(red: 0.90, green: 0.65, blue: 0.20)
        case .greyGreasy: return Color(red: 0.60, green: 0.60, blue: 0.58)
        case .redStreaks: return Color(red: 0.80, green: 0.20, blue: 0.20)
        case .whiteChalky: return Color(red: 0.93, green: 0.92, blue: 0.88)
        case .blackTarry: return Color(red: 0.12, green: 0.10, blue: 0.10)
        case .pinkPurple: return Color(red: 0.75, green: 0.35, blue: 0.60)
        }
    }
}

extension PetMode {
    var badgeColor: Color {
        switch self {
        case .baseline: return Color.secondary.opacity(0.5)
        case .watch: return Tier.monitor.color
        }
    }
}

/// Circular profile photo when the pet has one, emoji avatar otherwise.
struct PetAvatar: View {
    @EnvironmentObject var store: AppStore
    let pet: Pet
    var size: CGFloat = 44

    var body: some View {
        if let filename = pet.photoFilename,
           let image = UIImage(contentsOfFile: store.photoURL(filename).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Text(pet.avatar)
                .font(.system(size: size * 0.75))
                .frame(width: size, height: size)
        }
    }
}

/// A selectable capture chip. Ordinal, sober — no emoji on the clinical scale.
struct Chip: View {
    let label: String
    let isSelected: Bool
    var tint: Color = .accentColor
    /// A color axis shows its color: a dot the eye can scan without reading.
    var swatch: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let swatch {
                    Circle()
                        .fill(swatch)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                }
                Text(label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSelected ? tint.opacity(0.18) : Color(.secondarySystemBackground))
                )
                .overlay(
                    Capsule().stroke(isSelected ? tint : Color.clear, lineWidth: 1.5)
                )
                .foregroundColor(isSelected ? tint : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct TierBadge: View {
    let tier: Tier

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tier.symbol)
                .font(.caption2.weight(.bold))
            Text(tier.label)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tier.color.opacity(0.15)))
        .foregroundColor(tier.color)
    }
}

/// Note field shaped like the chips it lives among.
struct PillTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(DS.surface))
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Just now / Earlier today / Yesterday" chips, plus a clock-time picker that
/// appears for the retroactive options so the user picks the real time instead
/// of the app guessing one.
struct TimingPicker: View {
    @Binding var timing: LogTiming
    @Binding var pickedTime: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(LogTiming.allCases) { option in
                    Chip(label: option.label, isSelected: timing == option, tint: .accentColor) {
                        if timing != option {
                            timing = option
                            pickedTime = option.defaultDate
                        }
                    }
                }
            }
            if timing.needsTime {
                HStack {
                    Text(timing == .yesterday ? "Around what time yesterday?" : "Around what time?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    DatePicker("Time", selection: $pickedTime, in: timing.range, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: timing)
    }
}

/// Swipe-to-delete for rows that live in a ScrollView, where List's
/// `swipeActions` isn't available. A leftward drag slides the row to reveal a
/// trash button; a long swipe deletes outright. Only one row in a group stays
/// open at a time: rows share `openID` and close when another one opens.
struct SwipeToDelete<Content: View>: View {
    let id: UUID
    @Binding var openID: UUID?
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var dragging = false

    private let revealWidth: CGFloat = 72
    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                deleteAnimated()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: DS.rowRadius).fill(Color.red))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete entry")
            .opacity(offset < 0 ? 1 : 0)

            content
                .overlay {
                    // While open, a tap anywhere on the row closes it
                    // instead of reaching whatever the row does on tap.
                    if offset != 0 {
                        Button { close() } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    }
                }
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 18, coordinateSpace: .local)
                        .onChanged { value in
                            // Leave vertical drags to the ScrollView.
                            guard dragging || abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragging = true
                            if openID != id { openID = id }
                            let base: CGFloat = offset <= -revealWidth ? -revealWidth : 0
                            offset = min(0, base + value.translation.width)
                        }
                        .onEnded { _ in
                            dragging = false
                            if offset < -UIScreen.main.bounds.width * 0.55 {
                                deleteAnimated()
                            } else if offset < -revealWidth / 2 {
                                withAnimation(spring) { offset = -revealWidth }
                            } else {
                                close()
                            }
                        }
                )
        }
        .clipped()
        .onChange(of: openID) { current in
            if current != id && offset != 0 { close() }
        }
    }

    private func close() {
        withAnimation(spring) { offset = 0 }
        if openID == id { openID = nil }
    }

    private func deleteAnimated() {
        withAnimation(.easeInOut(duration: 0.2)) { offset = -UIScreen.main.bounds.width }
        if openID == id { openID = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation { onDelete() }
        }
    }
}
