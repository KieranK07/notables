// Print the CGWindowID of an app's largest on-screen window.
//
// Used so a screenshot can be taken of Notables *without* activating it — Kieran
// keeps working while the app is captured in place.
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Notables"
func windows(_ options: CGWindowListOption) -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([options, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]) ?? []
}

func largestWindow(in list: [[String: Any]]) -> (id: Int, area: Double) {
    var bestID = 0
    var bestArea = 0.0
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owner == target,
              let id = w[kCGWindowNumber as String] as? Int,
              let bounds = w[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { continue }
        // The menu-bar extra is a full-width 34pt strip; the real window is tall.
        if height < 200 { continue }
        let area = width * height
        if area > bestArea { bestArea = area; bestID = id }
    }
    return (bestID, bestArea)
}

// Prefer a visible window, but fall back to any window the app owns: Notables keeps
// running with its window closed or hidden, and screencapture -l can still read the
// window server's buffer for it.
var best = largestWindow(in: windows(.optionOnScreenOnly))
if best.id == 0 { best = largestWindow(in: windows(.optionAll)) }
let bestID = best.id

if bestID == 0 {
    FileHandle.standardError.write(Data("no on-screen window owned by \(target)\n".utf8))
    exit(2)
}
print(bestID)
