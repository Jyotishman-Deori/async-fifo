"""Render docs/report.html to a paginated PDF and stamp page numbers.

Chrome does the layout; it does not support CSS @page margin boxes, so the
footer and page numbers are stamped afterwards with PyMuPDF. The cover page is
deliberately left unstamped.

    python docs/make_pdf.py
"""
import os
import subprocess
import sys

import fitz

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "report.html")
RAW = os.path.join(HERE, "_report_raw.pdf")
OUT = os.path.join(HERE, "Async_FIFO_Report.pdf")

CHROME = next(
    (p for p in (
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    ) if os.path.exists(p)),
    None,
)
if CHROME is None:
    sys.exit("no Chrome or Edge found to render with")

FOOTER = "Dual-Clock Asynchronous FIFO  \u00b7  Jyotishman Deori"
INK = (0.42, 0.46, 0.50)
RULE = (0.84, 0.86, 0.89)

subprocess.run(
    [CHROME, "--headless", "--disable-gpu", "--no-pdf-header-footer",
     "--print-to-pdf-no-header", f"--print-to-pdf={RAW}",
     "file:///" + SRC.replace("\\", "/")],
    check=True, capture_output=True,
)

doc = fitz.open(RAW)
for i, page in enumerate(doc):
    if i == 0:
        continue  # cover carries its own footer
    w, h = page.rect.width, page.rect.height
    y = h - 34
    page.draw_line(fitz.Point(45, y - 9), fitz.Point(w - 45, y - 9),
                   color=RULE, width=0.5)
    page.insert_text(fitz.Point(45, y + 1), FOOTER,
                     fontname="helv", fontsize=7.5, color=INK)
    num = str(i + 1)
    tw = fitz.get_text_length(num, fontname="helv", fontsize=7.5)
    page.insert_text(fitz.Point(w - 45 - tw, y + 1), num,
                     fontname="helv", fontsize=7.5, color=INK)

doc.set_metadata({
    "title": "Dual-Clock Asynchronous FIFO: Design, Verification and Hardware Validation",
    "author": "Jyotishman Deori",
    "subject": "Clock domain crossing FIFO in Verilog, verified in simulation and on a PYNQ-Z2",
    "keywords": "FIFO, CDC, Gray code, synchroniser, Verilog, Vivado, PYNQ-Z2, Zynq",
})
doc.save(OUT, garbage=4, deflate=True)
doc.close()
os.remove(RAW)

print(f"{OUT}  ({os.path.getsize(OUT)} bytes)")
