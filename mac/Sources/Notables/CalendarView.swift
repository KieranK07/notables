import SwiftUI

/// The month, as a navigator. Lives in the middle column; the wide pane to its right
/// shows what the chosen day (and the fortnight after it) actually holds.
///
/// Deliberately quiet: a day carries small course-coloured dots, not blocks of
/// colour or counts. The only emphasis is a soft ring on today and a filled ring on
/// the day you're reading. Days already gone fade back. Late work is a muted clay
/// dot — present, not panicking.
struct CalendarView: View {
    @ObservedObject var model: AppModel
    @State private var month: Date = Calendar.current.startOfDay(for: Date())

    private let cal = Calendar.current
    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        let syms = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let first = cal.firstWeekday - 1
        return Array(syms[first...] + syms[..<first])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            weekdayRow
            grid
            legend
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .background(Theme.canvas)
    }

    // MARK: Legend — what the dots mean, and how much each course asks this month.
    private var legend: some View {
        let counts = monthCounts()
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(counts, id: \.0) { course, n in
                HStack(spacing: Theme.Space.s) {
                    CourseDot(course: course, size: 6)
                    Text(course).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Text("\(n)").font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.inkFaint)
                }
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.top, Theme.Space.xl)
    }

    /// Open items due in the shown month, by course. Busiest first.
    private func monthCounts() -> [(String, Int)] {
        let prefix = Dates.iso(month).prefix(7)
        var counts: [String: Int] = [:]
        for t in model.todos where !t.done {
            guard let due = t.due, due.hasPrefix(prefix) else { continue }
            counts[t.course ?? "—", default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 2) {
            Text(monthTitle)
                .font(Theme.Font.display).foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            navButton("chevron.left") { step(-1) }
            Button {
                month = cal.startOfDay(for: Date())
                model.calendarDay = Dates.iso(Date())
            } label: {
                Text("Today").font(Theme.Font.caption)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Theme.sunken, in: Capsule())
            }
            .buttonStyle(.plain)
            navButton("chevron.right") { step(1) }
        }
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.Space.xs)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.l)
    }

    private func navButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    private func step(_ n: Int) {
        if let d = cal.date(byAdding: .month, value: n, to: month) { month = d }
    }

    // MARK: Grid
    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                Text(s).sectionLabel().frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, Theme.Space.s)
    }

    private var grid: some View {
        let days = monthDays()
        let today = cal.startOfDay(for: Date())
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
            ForEach(days, id: \.self) { date in
                if let date {
                    DayCell(date: date,
                            iso: Dates.iso(date),
                            model: model,
                            isToday: cal.isDateInToday(date),
                            isPast: date < today,
                            isSelected: Dates.iso(date) == model.calendarDay)
                        .onTapGesture { model.calendarDay = Dates.iso(date) }
                } else {
                    Color.clear.frame(height: DayCell.height)
                }
            }
        }
    }

    /// The month's days, padded with nils so the first lands on the right weekday.
    private func monthDays() -> [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: month))
        else { return [] }
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: leading)
        for d in range {
            if let day = cal.date(byAdding: .day, value: d - 1, to: first) { out.append(day) }
        }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }
}

/// One square in the month grid.
private struct DayCell: View {
    static let height: CGFloat = 54

    let date: Date
    let iso: String
    @ObservedObject var model: AppModel
    let isToday: Bool
    let isPast: Bool
    let isSelected: Bool

    var body: some View {
        let due = model.todos(on: iso)
        let hasClass = !model.notes(on: iso).isEmpty
        let late = due.contains { $0.dueStyle == .overdue }

        VStack(spacing: 4) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(Theme.Font.numeral)
                .foregroundStyle(numeralColor)
                .frame(width: 24, height: 24)
                .background {
                    if isSelected { Circle().fill(Theme.accent) }
                    else if isToday { Circle().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5) }
                }

            // At most four dots: past that the day is busy and the count stops helping.
            HStack(spacing: 3) {
                ForEach(Array(dotCourses(due).prefix(4).enumerated()), id: \.offset) { _, c in
                    Circle()
                        .fill(late ? Theme.overdue : Theme.courseColor(c))
                        .frame(width: 4.5, height: 4.5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(hasClass ? Theme.accentSoft : Color.clear)
        }
        .contentShape(Rectangle())
    }

    private var numeralColor: Color {
        if isSelected { return Theme.surfaceHigh }
        if isToday { return Theme.accent }
        return isPast ? Theme.inkFaint : Theme.ink
    }

    private func dotCourses(_ todos: [Todo]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in todos {
            let c = t.course ?? "—"
            if seen.insert(c).inserted { out.append(c) }
        }
        return out
    }
}

// MARK: - The chosen day, and the fortnight after it

struct CalendarDayView: View {
    @ObservedObject var model: AppModel
    private let cal = Calendar.current

    var body: some View {
        let selected = model.calendarDay
        let upcoming = upcomingDays(after: selected)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                daySection(selected, hero: true)

                if !upcoming.isEmpty {
                    Text("Next two weeks").sectionLabel()
                        .padding(.top, Theme.Space.xxl)
                        .padding(.bottom, Theme.Space.l)
                    ForEach(upcoming, id: \.self) { iso in
                        daySection(iso, hero: false)
                    }
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
    }

    /// Days after the chosen one that hold something. Empty days are simply absent.
    private func upcomingDays(after iso: String) -> [String] {
        guard let start = Dates.day(iso) else { return [] }
        return (1...14).compactMap { n -> String? in
            guard let d = cal.date(byAdding: .day, value: n, to: start) else { return nil }
            let i = Dates.iso(d)
            return (model.todos(on: i).isEmpty && model.notes(on: i).isEmpty) ? nil : i
        }
    }

    @ViewBuilder
    private func daySection(_ iso: String, hero: Bool) -> some View {
        let due = model.todos(on: iso)
        let lectures = model.notes(on: iso)

        VStack(alignment: .leading, spacing: hero ? Theme.Space.m : Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(Dates.longDay(iso))
                    .font(hero ? Theme.Font.hero : Theme.Font.title)
                    .foregroundStyle(Theme.ink)
                if let near = nearLabel(iso) {
                    Text(near).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                }
            }

            if hero && due.isEmpty && lectures.isEmpty {
                Text("Nothing due").font(Theme.Font.body).foregroundStyle(Theme.inkFaint)
            }

            ForEach(lectures) { n in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.courseColor(n.course))
                        .frame(width: 14)
                    Text(n.topic?.isEmpty == false ? n.topic! : n.title)
                        .font(Theme.Font.body).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(n.course).font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                }
                .padding(.vertical, 5)
            }

            ForEach(due) { t in
                DeadlineRow(todo: t, model: model, showRelative: false)
            }
        }
        .padding(.bottom, hero ? 0 : Theme.Space.l)
    }

    /// Only the words that help: yesterday, today, tomorrow.
    private func nearLabel(_ iso: String) -> String? {
        guard let n = Dates.daysFromToday(iso), (-1...1).contains(n) else { return nil }
        return Dates.relative(iso)
    }
}

// MARK: - A single deadline

struct DeadlineRow: View {
    let todo: Todo
    @ObservedObject var model: AppModel
    var showRelative = true
    /// In the Deadlines list a row opens in the detail pane; elsewhere it just sits.
    var selectable = false

    @State private var hovering = false

    var body: some View {
        let selected = selectable && model.selectedTodoID == todo.id

        HStack(alignment: .top, spacing: Theme.Space.s) {
            Button { model.setTodoDone(todo, !todo.done) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(todo.done ? Theme.accent : Theme.inkFaint)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(todo.text)
                    .font(Theme.Font.body)
                    .foregroundStyle(todo.done ? Theme.inkFaint : Theme.ink)
                    .strikethrough(todo.done, color: Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Space.s) {
                    if let c = todo.course {
                        HStack(spacing: 4) {
                            CourseDot(course: c, size: 5)
                            Text(c).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    if showRelative, let d = todo.dueDisplay {
                        Text(d).font(Theme.Font.caption).foregroundStyle(todo.dueStyle.color)
                    } else if let t = todo.dueTime {
                        Text(t).font(Theme.Font.caption).foregroundStyle(todo.dueStyle.color)
                    }
                    if let p = todo.pointsDisplay {
                        Text(p).font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                    }
                    if !todo.isAssignment {
                        Text("from lecture").font(Theme.Font.caption).foregroundStyle(Theme.inkFaint)
                    }
                }
            }

            Spacer(minLength: 0)

            if hovering, let u = todo.url, let url = URL(string: u) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                }
                .help("Open in Canvas")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, selectable ? 10 : 0)
        .background {
            if selectable {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(selected ? Theme.selection : (hovering ? Theme.hover : Color.clear))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if selectable { model.selectedTodoID = todo.id } }
        .onHover { hovering = $0 }
    }
}
