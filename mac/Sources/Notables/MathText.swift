import Foundation

/// Claude writes some maths as LaTeX (`$\Delta S_{universe} > 0$`). Obsidian renders that,
/// but raw `$…$` is unreadable in the app, so convert the common cases to Unicode. This is
/// a display convenience over a known, narrow vocabulary — not a LaTeX engine.
enum MathText {

    private static let symbols: [(String, String)] = [
        ("\\Delta", "Δ"), ("\\delta", "δ"), ("\\Sigma", "Σ"), ("\\sigma", "σ"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\lambda", "λ"),
        ("\\mu", "μ"), ("\\pi", "π"), ("\\theta", "θ"), ("\\omega", "ω"),
        ("\\rightarrow", "→"), ("\\to", "→"), ("\\leftarrow", "←"),
        ("\\Rightarrow", "⇒"), ("\\leftrightarrow", "↔"), ("\\rightleftharpoons", "⇌"),
        ("\\geq", "≥"), ("\\ge", "≥"), ("\\leq", "≤"), ("\\le", "≤"),
        ("\\neq", "≠"), ("\\approx", "≈"), ("\\equiv", "≡"), ("\\propto", "∝"),
        ("\\times", "×"), ("\\cdot", "·"), ("\\pm", "±"), ("\\infty", "∞"),
        ("\\sum", "∑"), ("\\int", "∫"), ("\\partial", "∂"), ("\\sqrt", "√"),
        ("\\log", "log"), ("\\ln", "ln"), ("\\exp", "exp"), ("\\circ", "°"),
        ("\\left", ""), ("\\right", ""), ("\\,", " "), ("\\;", " "), ("\\!", "")
    ]

    /// Greek letters bind tightly to what follows them; operators and relations don't.
    private static let absorbsFollowingSpace: Set<String> = [
        "\\Delta", "\\delta", "\\Sigma", "\\sigma", "\\alpha", "\\beta",
        "\\gamma", "\\lambda", "\\mu", "\\pi", "\\theta", "\\omega",
        "\\partial", "\\sqrt", "\\left", "\\right"
    ]

    private static let subscripts: [Character: Character] = [
        "0":"₀","1":"₁","2":"₂","3":"₃","4":"₄","5":"₅","6":"₆","7":"₇","8":"₈","9":"₉",
        "a":"ₐ","e":"ₑ","i":"ᵢ","j":"ⱼ","o":"ₒ","x":"ₓ","n":"ₙ","m":"ₘ","p":"ₚ","s":"ₛ","t":"ₜ"
    ]
    private static let superscripts: [Character: Character] = [
        "0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹",
        "+":"⁺","-":"⁻","n":"ⁿ","i":"ⁱ"
    ]

    /// Replaces `$…$` spans with a Unicode rendering, leaving everything else untouched.
    static func render(_ input: String) -> String {
        guard input.contains("$") else { return input }
        var out = ""
        var rest = Substring(input)

        while let open = rest.firstIndex(of: "$") {
            out += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            // `$$` display maths — treat the inner span the same way.
            let isDisplay = afterOpen < rest.endIndex && rest[afterOpen] == "$"
            let contentStart = isDisplay ? rest.index(after: afterOpen) : afterOpen
            let closeToken: Character = "$"
            guard contentStart <= rest.endIndex,
                  let close = rest[contentStart...].firstIndex(of: closeToken) else {
                out += rest[open...]                       // unbalanced — leave as written
                return out
            }
            let span = String(rest[contentStart..<close])
            var after = rest.index(after: close)
            let following = after < rest.endIndex ? rest[after] : " "
            guard looksLikeMaths(span, followedBy: following) else {
                // Almost certainly currency ("$5 and $10"), not maths. Leave it alone.
                out.append("$")
                rest = rest[afterOpen...]
                continue
            }
            out += convert(span)
            if isDisplay, after < rest.endIndex, rest[after] == "$" { after = rest.index(after: after) }
            rest = rest[after...]
        }
        out += rest
        return out
    }

    /// `$…$` is also how people write money. Only treat a span as maths when it carries a
    /// real signal — a TeX command, a sub/superscript, or a relation — or is a bare number
    /// that isn't the start of a "$5 and $10" run.
    private static func looksLikeMaths(_ span: String, followedBy next: Character) -> Bool {
        if span.isEmpty { return false }
        if span.contains(where: { "\\^_=<>".contains($0) }) { return true }
        let bareNumber = span.allSatisfy { $0.isNumber || $0 == "." }
        return bareNumber && !next.isNumber
    }

    private static func convert(_ math: String) -> String {
        var s = math
        // In TeX `\Delta S` sets as "ΔS" — the space is only a token separator, so a Greek
        // letter absorbs it. Relations and operator names do NOT: `k \log W` is "k log W"
        // and `\geq 0` is "≥ 0".
        for (tex, uni) in symbols where absorbsFollowingSpace.contains(tex) {
            s = s.replacingOccurrences(of: tex + " ", with: uni)
        }
        for (tex, uni) in symbols { s = s.replacingOccurrences(of: tex, with: uni) }
        s = applyScript(s, marker: "_", table: subscripts)
        s = applyScript(s, marker: "^", table: superscripts)
        s = s.replacingOccurrences(of: "{", with: "")
             .replacingOccurrences(of: "}", with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Turns `_{universe}` / `_2` into Unicode when every character has a mapping,
    /// otherwise keeps readable ASCII rather than emitting half-converted mush.
    private static func applyScript(_ input: String, marker: Character,
                                    table: [Character: Character]) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            guard input[i] == marker else { out.append(input[i]); i = input.index(after: i); continue }
            var j = input.index(after: i)
            guard j < input.endIndex else { break }
            var body = ""
            if input[j] == "{" {
                j = input.index(after: j)
                while j < input.endIndex, input[j] != "}" { body.append(input[j]); j = input.index(after: j) }
                if j < input.endIndex { j = input.index(after: j) }
            } else {
                body.append(input[j]); j = input.index(after: j)
            }
            if !body.isEmpty, body.allSatisfy({ table[$0] != nil }) {
                out += String(body.map { table[$0]! })
            } else {
                // Readable ASCII fallback: S_universe, not S_(universe).
                out += "\(marker)\(body)"
            }
            i = j
        }
        return out
    }
}
