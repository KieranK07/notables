import SwiftUI

/// Renders the note format defined in docs/PROTOCOL.md. We control the markdown we
/// generate, so a purpose-built renderer beats a general one on typography and lets
/// checkbox action items render as real checkboxes.
struct MarkdownView: View {
    let markdown: String
    /// The note header already shows the title and meta line; don't set them twice.
    var dropLeadingTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(for: block, first: i == 0)
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [Block] {
        var b = Block.parse(markdown)
        guard dropLeadingTitle else { return b }
        if case .heading(1, _)? = b.first { b.removeFirst() }
        // The italic "*Course · date · duration*" line that follows the title.
        if case .paragraph(let p)? = b.first,
           (p.hasPrefix("*") && p.hasSuffix("*")) || (p.hasPrefix("_") && p.hasSuffix("_")) {
            b.removeFirst()
        }
        return b
    }

    @ViewBuilder
    private func view(for block: Block, first: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? Theme.Font.hero : level == 2 ? Theme.Font.readingHeading : Theme.Font.readingSub)
                .foregroundStyle(Theme.ink)
                .padding(.top, first ? 0 : level == 1 ? 0 : level == 2 ? 26 : 18)
                .padding(.bottom, level == 1 ? 4 : 8)

        case .paragraph(let text):
            Text(inline(text))
                .font(Theme.Font.reading)
                .foregroundStyle(Theme.ink)
                .lineSpacing(5)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Theme.inkFaint)
                    .frame(width: 4, height: 4)
                    .padding(.top, 7)
                Text(inline(text)).font(Theme.Font.reading).foregroundStyle(Theme.ink).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.bottom, 6)

        case .checkbox(let checked, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Theme.accent : Theme.inkFaint)
                    .font(.system(size: 13))
                Text(inline(text))
                    .font(Theme.Font.reading)
                    .strikethrough(checked, color: Theme.inkFaint)
                    .foregroundStyle(checked ? Theme.inkFaint : Theme.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 7)

        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.45)).frame(width: 2)
                Text(inline(text)).font(Theme.Font.reading).italic().foregroundStyle(Theme.inkMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 12)

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .padding(Theme.Space.m)
            }
            .background(Theme.sunken,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .padding(.bottom, 14)

        case .rule:
            Divider().overlay(Theme.hairline).padding(.vertical, 16)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        let text = MathText.render(s)
        return (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, Int)
        case checkbox(Bool, String)
        case quote(String)
        case code(String)
        case rule

        static func parse(_ md: String) -> [Block] {
            var blocks: [Block] = []
            var paragraph: [String] = []
            var codeLines: [String] = []
            var inCode = false

            func flushParagraph() {
                let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paragraph = []
            }

            for rawLine in md.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

                if line.hasPrefix("```") {
                    if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines = [] }
                    else { flushParagraph() }
                    inCode.toggle()
                    continue
                }
                if inCode { codeLines.append(rawLine); continue }

                if line.isEmpty { flushParagraph(); continue }

                if line == "---" || line == "***" || line == "___" {
                    flushParagraph(); blocks.append(.rule); continue
                }
                if line.hasPrefix("#") {
                    flushParagraph()
                    let level = line.prefix(while: { $0 == "#" }).count
                    blocks.append(.heading(min(level, 3),
                        String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
                if line.hasPrefix("> ") {
                    flushParagraph(); blocks.append(.quote(String(line.dropFirst(2)))); continue
                }
                if let box = checkboxContent(line) {
                    flushParagraph(); blocks.append(.checkbox(box.0, box.1)); continue
                }
                if let bullet = bulletContent(rawLine) {
                    flushParagraph(); blocks.append(.bullet(bullet.0, bullet.1)); continue
                }
                paragraph.append(line)
            }
            if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
            flushParagraph()
            return blocks
        }

        private static func checkboxContent(_ line: String) -> (Bool, String)? {
            for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "] {
                if line.hasPrefix(marker) {
                    let checked = marker.lowercased().contains("[x]")
                    return (checked, String(line.dropFirst(marker.count)))
                }
            }
            return nil
        }

        private static func bulletContent(_ raw: String) -> (String, Int)? {
            let indent = raw.prefix(while: { $0 == " " }).count
            let line = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                return (String(line.dropFirst(2)), indent / 2)
            }
            // "1. item"
            if let dot = line.firstIndex(of: "."),
               line.distance(from: line.startIndex, to: dot) <= 2,
               Int(line[line.startIndex..<dot]) != nil {
                let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                return (rest, indent / 2)
            }
            return nil
        }
    }
}
