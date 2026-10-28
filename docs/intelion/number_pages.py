# -*- coding: utf-8 -*-
"""Stamps page numbers (bottom centre, from page 2) onto the PDF that build.py printed. Needs pypdf and reportlab."""
import io, sys
from pypdf import PdfReader, PdfWriter
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

src = sys.argv[1]
pdfmetrics.registerFont(TTFont("TNR", "/System/Library/Fonts/Supplemental/Times New Roman.ttf"))
reader, writer = PdfReader(src), PdfWriter()
for i, page in enumerate(reader.pages, start=1):
    if i > 1:
        w, h = float(page.mediabox.width), float(page.mediabox.height)
        buf = io.BytesIO()
        c = canvas.Canvas(buf, pagesize=(w, h))
        c.setFont("TNR", 11)
        c.drawCentredString(w / 2, 28, str(i))
        c.save()
        page.merge_page(PdfReader(buf).pages[0])
    writer.add_page(page)
with open(src, "wb") as f:
    writer.write(f)
print(f"{src}: {len(reader.pages)} pages numbered")
