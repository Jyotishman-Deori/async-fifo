"""Build docs/Async_FIFO_Report.pdf from docs/report.html.

Chrome lays the document out, because it implements print CSS properly. Two
things it does not implement are handled here afterwards with PyMuPDF:

  * Page numbers in the Contents. Chrome has no target-counter(), so the
    document is rendered once, each heading is located in that output, the
    numbers are substituted into the HTML, and it is rendered again.
    Pagination is unaffected because every number sits in a fixed-width
    right-aligned slot, so filling one in cannot reflow a line.

  * Running headers and folios. Chrome has no @page margin boxes, so the
    header, its rule and the centred page number are stamped onto every page
    except the cover.

The document outline and metadata are set at the same time.

    python docs/make_pdf.py
"""

import os
import re
import subprocess
import sys

import fitz

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "report.html")
TMP_HTML = os.path.join(HERE, "_report_pass2.html")
RAW = os.path.join(HERE, "_report_raw.pdf")
OUT = os.path.join(HERE, "Async_FIFO_Report.pdf")

TITLE = "Design and Verification of a Dual-Clock Asynchronous FIFO"
AUTHOR = "Jyotishman Deori"
HDR_L = "Jyotishman Deori \u2014 25M1186"
HDR_R = "Dual-Clock Asynchronous FIFO"

INK = (0.0, 0.0, 0.0)

CHROME = next(
    (p for p in (
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    ) if os.path.exists(p)),
    None,
)
if CHROME is None:
    sys.exit("no Chrome or Edge available to render with")


def render(html_path, pdf_path):
    if os.path.exists(pdf_path):
        os.remove(pdf_path)
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--no-pdf-header-footer",
         "--print-to-pdf-no-header", f"--print-to-pdf={pdf_path}",
         "file:///" + html_path.replace("\\", "/")],
        check=True, capture_output=True,
    )
    if not os.path.exists(pdf_path):
        sys.exit("chrome produced no pdf")


def locate(doc, needle, floor):
    """First page index at or after `floor` that contains `needle`.

    The floor matters: the Contents and the lists of figures and tables repeat
    the heading text verbatim, so an unfiltered search would return a front
    matter page every time.
    """
    for i in range(floor, doc.page_count):
        if doc[i].search_for(needle):
            return i
    return None


# ------------------------------------------------------------------ pass 1
html = open(SRC, encoding="utf-8").read()
render(SRC, RAW)

doc = fitz.open(RAW)

body_start = None
for i in range(doc.page_count):
    if doc[i].search_for("1. Introduction"):
        body_start = i
        break
if body_start is None:
    sys.exit("could not find the start of the body")

pages = {}
for target in re.findall(r'data-find="([^"]+)"', html):
    pages[target] = locate(doc, target, body_start)
doc.close()

unresolved = sorted(t for t, p in pages.items() if p is None)
if unresolved:
    sys.exit("unresolved references:\n  " + "\n  ".join(unresolved))

# ------------------------------------------------------------------ pass 2
html2 = re.sub(
    r'<span class="pn" data-find="([^"]+)"></span>',
    lambda m: f'<span class="pn" data-find="{m.group(1)}">{pages[m.group(1)]}</span>',
    html,
)
open(TMP_HTML, "w", encoding="utf-8").write(html2)
render(TMP_HTML, RAW)

doc = fitz.open(RAW)
W, H = doc[0].rect.width, doc[0].rect.height
LM, RM = 62.4, W - 62.4

for i, page in enumerate(doc):
    if i == 0:
        continue  # the cover takes no running head or folio

    page.insert_text(fitz.Point(LM, 46), HDR_L,
                     fontname="tiro", fontsize=8.6, color=INK)
    tw = fitz.get_text_length(HDR_R, fontname="tiro", fontsize=8.6)
    page.insert_text(fitz.Point(RM - tw, 46), HDR_R,
                     fontname="tiro", fontsize=8.6, color=INK)
    page.draw_line(fitz.Point(LM, 52), fitz.Point(RM, 52),
                   color=INK, width=0.7)

    folio = str(i)
    fw = fitz.get_text_length(folio, fontname="tiro", fontsize=9.5)
    page.insert_text(fitz.Point((W - fw) / 2, H - 34), folio,
                     fontname="tiro", fontsize=9.5, color=INK)

# ------------------------------------------------------------------ outline
FRONT = ("Abstract", "Contents", "List of Figures")
SECTIONS = [
    ("Abstract", "Abstract"),
    ("Contents", "Contents"),
    ("List of Figures", "List of Figures"),
    ("1  Introduction", "1. Introduction"),
    ("2  Literature Review", "2. Literature Review"),
    ("3  Background", "3. Background"),
    ("4  Methodology", "4. Methodology"),
    ("5  Results and Discussion", "5. Results and Discussion"),
    ("6  Conclusion", "6. Conclusion"),
    ("7  Future Work", "7. Future Work"),
    ("References", "References"),
]

toc = []
for label, needle in SECTIONS:
    floor = 0 if needle in FRONT else body_start
    p = locate(doc, needle, floor)
    if p is not None:
        toc.append([1, label, p + 1])
if toc:
    doc.set_toc(toc)

doc.set_metadata({
    "title": TITLE,
    "author": AUTHOR,
    "subject": "Clock domain crossing FIFO in Verilog, verified in simulation, "
               "synthesis and on a PYNQ-Z2 board",
    "keywords": "FIFO, CDC, Gray code, synchroniser, metastability, Verilog, "
                "SystemVerilog, SVA, Vivado, PYNQ-Z2, Zynq-7020",
})
doc.save(OUT, garbage=4, deflate=True)
n_pages = doc.page_count
doc.close()

os.remove(RAW)
os.remove(TMP_HTML)

print(f"{OUT}\n  {n_pages} pages, {os.path.getsize(OUT)} bytes")
