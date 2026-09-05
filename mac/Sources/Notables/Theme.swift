import SwiftUI
import AppKit

/// The visual language.
///
/// The brief: studying is stressful enough. Nothing here should add to it. That
/// means warm paper rather than clinical white, ink rather than pure black, one
/// quiet sage accent instead of saturated blue, and *muted clay* for something
/// overdue instead of an alarm red. Deadlines are shown honestly but never shouted.
///
/// Restraint is the style — generous space, hairline separators, soft radii, almost
/// no shadow. Not brutalism, not corporate dashboard.
enum Theme {

    private static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    private static func dyn4(_ light: (Double, Double, Double, Double),
                             _ dark: (Double, Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    // MARK: Surfaces — warm, never pure white or pure black
    static let canvas      = dyn((0.969, 0.961, 0.945), (0.102, 0.098, 0.090))
    static let surface     = dyn((0.992, 0.988, 0.980), (0.137, 0.133, 0.125))
    static let surfaceHigh = dyn((1.000, 1.000, 1.000), (0.169, 0.165, 0.157))
    static let sunken      = dyn((0.941, 0.929, 0.910), (0.078, 0.075, 0.070))

    // MARK: Ink — warm near-black, never #000
    static let ink       = dyn((0.173, 0.165, 0.149), (0.929, 0.918, 0.894))
    static let inkMuted  = dyn((0.420, 0.400, 0.376), (0.655, 0.639, 0.616))
    static let inkFaint  = dyn((0.604, 0.584, 0.553), (0.451, 0.439, 0.424))

    // MARK: Accents
    /// Sage. Calm, low-saturation, reads as "considered" rather than "urgent".
    static let accent     = dyn((0.404, 0.545, 0.463), (0.561, 0.702, 0.612))
    static let accentSoft = dyn((0.404, 0.545, 0.463), (0.561, 0.702, 0.612)).opacity(0.14)

    /// Due soon. Warm sand, not a warning triangle.
    static let soon    = dyn((0.706, 0.522, 0.298), (0.851, 0.663, 0.420))
    /// Overdue. Muted terracotta — visible, deliberately not alarming.
    static let overdue = dyn((0.686, 0.376, 0.286), (0.824, 0.514, 0.416))
    /// Recording. Reads as live without being an emergency.
    static let recordRed = dyn((0.729, 0.353, 0.337), (0.847, 0.478, 0.455))

    static let hairline = dyn((0.173, 0.165, 0.149), (0.929, 0.918, 0.894)).opacity(0.09)

    /// A selected row: a wash of the accent under ink text, never a filled block
    /// with white text. Dark mode needs a little more of it to read at all.
    static let selection = dyn4((0.404, 0.545, 0.463, 0.16), (0.561, 0.702, 0.612, 0.22))
    /// Pointer over a row. Barely there.
    static let hover     = dyn4((0.173, 0.165, 0.149, 0.045), (0.929, 0.918, 0.894, 0.05))

    // Kept for older call sites.
    static let cardBackground = surface

    // MARK: Course colours — one harmonious family, all similar chroma so no
    // single course ever shouts louder than another.
    private static let coursePalette: [Color] = [
        Color(red: 0.494, green: 0.608, blue: 0.522),   // sage
        Color(red: 0.753, green: 0.541, blue: 0.431),   // clay
        Color(red: 0.478, green: 0.576, blue: 0.671),   // dusty blue
        Color(red: 0.608, green: 0.502, blue: 0.596),   // plum
        Color(red: 0.541, green: 0.604, blue: 0.420),   // moss
        Color(red: 0.737, green: 0.498, blue: 0.447),   // terracotta
        Color(red: 0.431, green: 0.580, blue: 0.580),   // slate teal
        Color(red: 0.733, green: 0.627, blue: 0.439),   // sand
    ]

    /// Stable per-course colour, so a class always reads the same way.
    static func courseColor(_ name: String) -> Color {
        var hash = 5381
        for b in name.utf8 { hash = (hash &* 33) &+ Int(b) }
        return coursePalette[abs(hash) % coursePalette.count]
    }

    // MARK: Type scale
    enum Font {
        /// The one big thing on a pane: a note's title, the selected day, a deadline.
        static let hero     = SwiftUI.Font.system(size: 24, weight: .semibold)
        static let display  = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let title    = SwiftUI.Font.system(size: 14.5, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 12.5, weight: .medium)
        static let body     = SwiftUI.Font.system(size: 12.5)
        static let caption  = SwiftUI.Font.system(size: 11)
        static let micro    = SwiftUI.Font.system(size: 10, weight: .medium)
        static let numeral  = SwiftUI.Font.system(size: 12, weight: .medium).monospacedDigit()

        // Reading scale — the note body is the one place you sit and read, so it is
        // a step larger than the chrome around it.
        static let reading        = SwiftUI.Font.system(size: 14)
        static let readingHeading = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let readingSub     = SwiftUI.Font.system(size: 14.5, weight: .semibold)
    }

    // MARK: Space & shape
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
        static let l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius {
        static let small: CGFloat = 7, medium: CGFloat = 10, card: CGFloat = 14
    }
}

// MARK: - Building blocks

extension View {
    func cardStyle(padding: CGFloat = Theme.Space.l) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// A section heading: small, quiet, letterspaced. Used instead of heavy rules.
    func sectionLabel() -> some View {
        self.font(Theme.Font.micro)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(Theme.inkFaint)
    }
}

/// Lays children out left to right and wraps, like words. For tag pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > bounds.width { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Small pill for sections, tags and counts.
struct Pill: View {
    let text: String
    var color: Color = Theme.inkMuted
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.Font.micro)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(filled ? Theme.surfaceHigh : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(filled ? color : color.opacity(0.15), in: Capsule())
    }
}

/// A small course marker. A dot, not a block of colour.
struct CourseDot: View {
    let course: String
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(Theme.courseColor(course)).frame(width: size, height: size)
    }
}

// MARK: - Selection in the palette
//
// `.tint()` never reaches the highlight a macOS `List` draws for its selected row —
// that comes from AppKit and stays system blue. So the table is asked not to draw it,
// and the row draws its own wash of sage instead.

struct QuietSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(from: v) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: v) }
    }
    private static func apply(from v: NSView) {
        var cur = v.superview
        while let s = cur {
            if let table = s as? NSTableView {
                if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                return
            }
            cur = s.superview
        }
    }
}

extension View {
    /// Palette selection for a row inside `List(selection:)`. Keep the row's text in
    /// explicit Theme colours so nothing flips to white underneath it.
    func quietRowSelection(_ selected: Bool, inset: CGFloat = 8) -> some View {
        self.background(QuietSelection())
            .listRowBackground(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(selected ? Theme.selection : Color.clear)
                    .padding(.horizontal, inset))
    }
}

// MARK: - Dates
//
// Everything user-facing about deadlines goes through here, so "due" reads the same
// way in every part of the app.

enum DueStyle {
    case overdue, today, soon, later, none

    var color: Color {
        switch self {
        case .overdue: return Theme.overdue
        case .today:   return Theme.soon
        case .soon:    return Theme.inkMuted
        case .later:   return Theme.inkFaint
        case .none:    return Theme.inkFaint
        }
    }
}

enum Dates {
    static let cal = Calendar.current

    static func day(_ iso: String?) -> Date? {
        guard let iso, iso.count >= 10 else { return nil }
        var c = DateComponents()
        c.year = Int(iso.prefix(4))
        c.month = Int(iso.dropFirst(5).prefix(2))
        c.day = Int(iso.dropFirst(8).prefix(2))
        return cal.date(from: c)
    }

    static func iso(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func daysFromToday(_ iso: String?) -> Int? {
        guard let d = day(iso) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day
    }

    static func style(for iso: String?) -> DueStyle {
        guard let n = daysFromToday(iso) else { return .none }
        if n < 0 { return .overdue }
        if n == 0 { return .today }
        if n <= 7 { return .soon }
        return .later
    }

    /// "Overdue by 2 days", "Today", "Tomorrow", "Friday", "12 Oct".
    static func relative(_ iso: String?) -> String {
        guard let n = daysFromToday(iso), let d = day(iso) else { return "No date" }
        switch n {
        case ..<(-1): return "\(-n) days late"
        case -1:      return "Yesterday"
        case 0:       return "Today"
        case 1:       return "Tomorrow"
        case 2...6:
            let f = DateFormatter(); f.dateFormat = "EEEE"
            return f.string(from: d)
        default:
            let f = DateFormatter(); f.dateFormat = "d MMM"
            return f.string(from: d)
        }
    }

    /// "Friday 4 September" — the year only when it is not this one.
    static func longDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return f.string(from: d)
    }
    static func longDay(_ iso: String) -> String {
        guard let d = day(iso) else { return iso }
        return longDay(d)
    }

    /// "45 min", "1 h 05 min".
    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? String(format: "%d h %02d min", m / 60, m % 60) : "\(m) min"
    }

    /// "11:59 pm" from a full ISO timestamp, when one is known.
    static func timeOfDay(_ isoStamp: String?) -> String? {
        guard let isoStamp else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let d = parser.date(from: isoStamp) ?? ISO8601DateFormatter().date(from: isoStamp) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f.string(from: d)
    }
}
