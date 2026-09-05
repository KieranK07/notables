import SwiftUI
import PDFKit
import QuickLookUI
import AppKit

/// Renders an actual course file — PDF, Word, PowerPoint — rather than only the text
/// that was pulled out of it.
///
/// PDFs go through PDFKit, which gives real page navigation, selection and search.
/// Everything else goes through QuickLook, which is how Finder previews .docx and
/// .pptx, so it handles the Office formats without this app carrying a parser.
struct FilePreview: View {
    let url: URL

    private var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }

    var body: some View {
        Group {
            if isPDF {
                PDFKitView(url: url)
            } else {
                QuickLookPreview(url: url)
            }
        }
        // Identity per URL. AppKit preview views are reused aggressively when only a
        // property changes, and a stale PDFView or QLPreviewView is exactly the kind
        // of bug that shows the previous document forever. Rebuilding is cheap.
        .id(url)
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .textBackgroundColor
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        v.autostarts = true
        v.previewItem = url as QLPreviewItem
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem?.previewItemURL) != url {
            v.previewItem = url as QLPreviewItem
            v.refreshPreviewItem()
        }
    }
}
