#!/usr/bin/env python3
"""Text extraction for Canvas course materials.

Reads a JSON job on stdin, writes a JSON result on stdout:

    in :  {"input": "<ascii path>", "output": "<ascii path>", "kind": "pdf"}
    out:  {"ok": true, "chars": 12345, "pages": 20, "method": "pypdf"}

BOTH PATHS ARE PURE ASCII, BY CONTRACT. Canvas filenames are full of dashes,
smart quotes and accents, and this project has already lost a transcript to a
Windows Node->Python path round-trip mangling an em dash (see CLAUDE.md). Node
downloads to a scratch path keyed by the Canvas file id, and Node alone renames
the result into the vault. Python never sees a pretty name.

Only PDF needs a third-party module (pypdf). Office formats are zip+XML, which
the standard library handles, so a missing pypdf degrades exactly one format -
and says so out loud rather than emitting empty text.
"""
import contextlib
import html as htmllib
import json
import logging
import os
import re
import sys
import zipfile


def extract_pdf(path, ocr=False, ocr_max_pages=40, ocr_dpi=200):
    try:
        from pypdf import PdfReader
        method = "pypdf"
    except ImportError:
        try:
            from PyPDF2 import PdfReader  # type: ignore
            method = "PyPDF2"
        except ImportError:
            raise RuntimeError(
                "no PDF library available - run: "
                "%s -m pip install pypdf" % os.path.basename(sys.executable))
    reader = PdfReader(path)
    if getattr(reader, "is_encrypted", False):
        try:
            reader.decrypt("")
        except Exception:
            raise RuntimeError("PDF is password protected")
    pages = []
    for page in reader.pages:
        try:
            pages.append(page.extract_text() or "")
        except Exception as e:                      # one bad page must not lose the rest
            pages.append("[page could not be extracted: %s]" % e)
    text = "\n\n".join(pages)
    n = len(reader.pages) or 1

    if ocr and len(text.strip()) < OCR_TRIGGER_CHARS_PER_PAGE * n:
        ocr_text, done, total = ocr_pdf(path, ocr_max_pages, ocr_dpi)
        # Keep whichever actually says more. A scan gives OCR everything; a mostly
        # digital PDF with one scanned insert keeps its real text layer.
        if len(ocr_text.strip()) > len(text.strip()):
            note = ""
            if done < total:
                note = "\n\n[OCR stopped after %d of %d pages]" % (done, total)
            return ocr_text + note, total, "ocr"
    return text, len(reader.pages), method


# A PDF this sparse is a scan, not a document: below this many characters per page
# there is effectively no text layer worth having.
OCR_TRIGGER_CHARS_PER_PAGE = 25


def ocr_pdf(path, max_pages, dpi):
    """Render each page and read it. Used only when a PDF has no usable text layer.

    pypdfium2 renders (a pip wheel bundling PDFium - no external binary), RapidOCR
    recognises via onnxruntime on the CPU. Roughly 7s a page, which is why this only
    ever runs as a fallback and is page-capped.
    """
    try:
        import numpy as np
        import pypdfium2 as pdfium
        from rapidocr_onnxruntime import RapidOCR
    except ImportError as e:
        raise RuntimeError(
            "OCR needs pypdfium2 + rapidocr-onnxruntime in the venv (%s)" % e)

    doc = pdfium.PdfDocument(path)
    total = len(doc)
    limit = min(total, max_pages) if max_pages else total
    engine = RapidOCR()
    pages = []
    for i in range(limit):
        bitmap = doc[i].render(scale=dpi / 72.0)
        result, _ = engine(np.array(bitmap.to_pil().convert("RGB")))
        lines = [r[1] for r in (result or [])]
        pages.append("\n".join(lines))
    return "\n\n".join(pages), limit, total


_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t]+")


def _xml_text(blob, tag):
    """Pull the text out of every <tag>...</tag> in an Office XML part."""
    parts = re.findall(r"<%s[^>]*>(.*?)</%s>" % (tag, tag), blob, re.S)
    return [_TAG.sub("", p) for p in parts]


def extract_pptx(path):
    slides = []
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist()
                 if re.match(r"ppt/slides/slide\d+\.xml$", n)]
        names.sort(key=lambda n: int(re.search(r"(\d+)", n).group(1)))
        for i, n in enumerate(names, 1):
            blob = z.read(n).decode("utf-8", "replace")
            runs = _xml_text(blob, "a:t")
            body = "\n".join(r for r in runs if r.strip())
            slides.append("--- slide %d ---\n%s" % (i, body))
        # Speaker notes are often where the actual explanation lives.
        for n in sorted(x for x in z.namelist()
                        if re.match(r"ppt/notesSlides/notesSlide\d+\.xml$", x)):
            blob = z.read(n).decode("utf-8", "replace")
            runs = [r for r in _xml_text(blob, "a:t") if r.strip()]
            if runs:
                slides.append("--- notes (%s) ---\n%s" % (n.split("/")[-1], "\n".join(runs)))
    return "\n\n".join(slides), len(slides), "zipfile"


def extract_docx(path):
    with zipfile.ZipFile(path) as z:
        blob = z.read("word/document.xml").decode("utf-8", "replace")
    blob = blob.replace("<w:tab/>", "\t").replace("<w:br/>", "\n")
    # Paragraph by paragraph. Extracting every <w:t> in one pass and joining would
    # run the paragraphs together, because the breaks live between the runs.
    paras = []
    for chunk in re.split(r"</w:p>", blob):
        runs = _xml_text(chunk, "w:t")
        if runs:
            paras.append("".join(runs))
    return "\n".join(paras), len(paras), "zipfile"


# Block-level tags whose close should become a line break. Canvas syllabus bodies
# are heading- and table-heavy, and without these the text runs together into one
# unsearchable line ("Le ChatelierSection 4.3").
_BLOCK_END = re.compile(
    r"(?i)<br\s*/?>|</(?:p|div|li|tr|h[1-6]|td|th|blockquote|section|article|ul|ol|table)>")


def extract_html(path):
    with open(path, "rb") as f:
        blob = f.read().decode("utf-8", "replace")
    blob = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", blob)
    blob = _BLOCK_END.sub("\n", blob)
    text = _TAG.sub("", blob)
    # htmllib.unescape handles the whole entity table - named, decimal and hex -
    # rather than the handful anyone remembers to list by hand.
    text = htmllib.unescape(text)
    text = text.replace("\u00a0", " ")
    return text, 1, "regex"


def extract_plain(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace"), 1, "plain"


HANDLERS = {
    "pdf": extract_pdf,
    "pptx": extract_pptx, "ppt": extract_pptx,
    "docx": extract_docx,
    "html": extract_html, "htm": extract_html,
    "txt": extract_plain, "md": extract_plain, "csv": extract_plain,
    "rtf": extract_plain, "json": extract_plain,
}


def tidy(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = _WS.sub(" ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return "\n".join(line.rstrip() for line in text.split("\n")).strip()


def main():
    job = json.loads(sys.stdin.read())
    src = job["input"]
    dst = job["output"]
    kind = str(job.get("kind", "")).lower().lstrip(".")

    handler = HANDLERS.get(kind)
    if kind == "pdf" and handler is not None:
        want_ocr = bool(job.get("ocr", False))
        max_pages = int(job.get("ocr_max_pages", 40))
        dpi = int(job.get("ocr_dpi", 200))
        handler = lambda p: extract_pdf(p, ocr=want_ocr, ocr_max_pages=max_pages, ocr_dpi=dpi)
    if handler is None:
        print(json.dumps({"ok": False, "error": "unsupported format: %s" % (kind or "?"),
                          "unsupported": True}))
        return 0

    # pypdf logs font warnings freely, and this script's stdout IS the protocol.
    # Send anything a library prints to stderr so a chatty PDF cannot corrupt the
    # JSON result the way a mangled path once corrupted a transcript.
    logging.getLogger("pypdf").setLevel(logging.ERROR)
    logging.getLogger("PyPDF2").setLevel(logging.ERROR)
    try:
        with contextlib.redirect_stdout(sys.stderr):
            text, pages, method = handler(src)
    except Exception as e:
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))
        return 0

    text = tidy(text)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(json.dumps({"ok": True, "chars": len(text), "pages": pages, "method": method}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
