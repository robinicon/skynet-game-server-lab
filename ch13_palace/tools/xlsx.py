#!/usr/bin/env python3
"""Minimal dependency-free XLSX reader/writer for the schema pipeline.

XLSX is a ZIP package of OOXML parts. We only need a subset:
  - strings written as inlineStr (no sharedStrings.xml needed)
  - numbers written as plain numeric cells
  - one header row + data rows per sheet

Public API:
    read_book(path) -> dict[str, list[list[str]]]
    write_book(path, sheets: dict[str, list[list[str]]]) -> None

No third-party dependency (openpyxl / pandas absent in WSL by design).
"""

import re
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships"
NS_CT = "http://schemas.openxmlformats.org/package/2006/content-types"


def _local(tag):
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def col_to_index(ref):
    """'A1'/'BC12' -> zero-based column index."""
    letters = re.match(r"[A-Za-z]+", ref)
    if not letters:
        raise ValueError("bad cell ref: " + ref)
    n = 0
    for ch in letters.group(0).upper():
        n = n * 26 + (ord(ch) - ord("A") + 1)
    return n - 1


def index_to_col(index):
    """zero-based column index -> 'A'/'BC'."""
    if index < 0:
        raise ValueError("negative column index")
    out = []
    n = index + 1
    while n:
        n, rem = divmod(n - 1, 26)
        out.append(chr(ord("A") + rem))
    return "".join(reversed(out))


def _xml_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def read_book(path):
    """Read workbook into {sheet_name: [[cell_text, ...], ...]}.

    Empty trailing cells are trimmed. Numbers come back as their string form.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(str(path))

    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())

        shared = []
        if "xl/sharedStrings.xml" in names:
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in root:
                if _local(si.tag) == "si":
                    shared.append("".join(t.text or "" for t in si.iter()
                                          if _local(t.tag) == "t"))

        wb = ET.fromstring(z.read("xl/workbook.xml"))
        sheets = []
        for node in wb.iter():
            if _local(node.tag) == "sheet":
                sheets.append((node.get("name"), node.get("{%s}id" % NS_REL)))

        rels = {}
        if "xl/_rels/workbook.xml.rels" in names:
            root = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
            for node in root:
                if _local(node.tag) == "Relationship":
                    rels[node.get("Id")] = node.get("Target")

        result = {}
        for index, (name, rid) in enumerate(sheets, 1):
            target = rels.get(rid, "worksheets/sheet%d.xml" % index)
            part = target.lstrip("/")
            if not part.startswith("xl/"):
                part = "xl/" + part
            if part not in names:
                part = "xl/worksheets/sheet%d.xml" % index
            if part not in names:
                result[name] = []
                continue

            root = ET.fromstring(z.read(part))
            rows = []
            for row_node in root.iter():
                if _local(row_node.tag) != "row":
                    continue
                cells = {}
                for c in row_node:
                    if _local(c.tag) != "c":
                        continue
                    ref = c.get("r") or ""
                    col = col_to_index(ref) if ref else len(cells)
                    ctype = c.get("t")
                    value = ""
                    if ctype == "inlineStr":
                        value = "".join(t.text or "" for t in c.iter()
                                        if _local(t.tag) == "t")
                    else:
                        v = next((n for n in c if _local(n.tag) == "v"), None)
                        if v is not None:
                            raw = v.text or ""
                            if ctype == "s":
                                try:
                                    value = shared[int(raw)]
                                except (ValueError, IndexError):
                                    value = ""
                            else:
                                value = raw
                    cells[col] = value
                if cells:
                    width = max(cells) + 1
                    rows.append([cells.get(i, "") for i in range(width)])
                else:
                    rows.append([])
            result[name] = rows
        return result


def _sheet_xml(rows):
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
           '<worksheet xmlns="%s"><sheetData>' % NS_MAIN]
    for r, row in enumerate(rows, 1):
        out.append('<row r="%d">' % r)
        for c, value in enumerate(row):
            ref = "%s%d" % (index_to_col(c), r)
            text = "" if value is None else str(value)
            if text == "":
                continue
            try:
                float(text)
                numeric = bool(re.fullmatch(r"[+-]?\d+(\.\d+)?([eE][+-]?\d+)?", text))
            except ValueError:
                numeric = False
            if numeric:
                out.append('<c r="%s"><v>%s</v></c>' % (ref, text))
            else:
                out.append('<c r="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>'
                           % (ref, _xml_escape(text)))
        out.append("</row>")
    out.append("</sheetData></worksheet>")
    return "".join(out)


def write_book(path, sheets):
    """Write {sheet_name: [[cell, ...], ...]} to a minimal valid XLSX."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    sheet_names = list(sheets.keys())
    content_types = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Types xmlns="%s">' % NS_CT,
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
    ]
    for i in range(len(sheet_names)):
        content_types.append(
            '<Override PartName="/xl/worksheets/sheet%d.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % (i + 1))
    content_types.append("</Types>")

    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s">'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>' % (NS_PKG_REL, NS_REL))

    wb = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
          '<workbook xmlns="%s" xmlns:r="%s"><sheets>' % (NS_MAIN, NS_REL)]
    wb_rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
               '<Relationships xmlns="%s">' % NS_PKG_REL]
    for i, name in enumerate(sheet_names, 1):
        wb.append('<sheet name="%s" sheetId="%d" r:id="rId%d"/>'
                  % (_xml_escape(name), i, i))
        wb_rels.append(
            '<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>'
            % (i, NS_REL, i))
    wb.append("</sheets></workbook>")
    wb_rels.append(
        '<Relationship Id="rId%d" Type="%s/styles" Target="styles.xml"/>'
        % (len(sheet_names) + 1, NS_REL))
    wb_rels.append("</Relationships>")

    styles = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="%s">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
        '<borders count="1"><border/></borders>'
        '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="1"><xf/></cellXfs>'
        '</styleSheet>' % NS_MAIN)

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "".join(content_types))
        z.writestr("_rels/.rels", root_rels)
        z.writestr("xl/workbook.xml", "".join(wb))
        z.writestr("xl/_rels/workbook.xml.rels", "".join(wb_rels))
        z.writestr("xl/styles.xml", styles)
        for i, name in enumerate(sheet_names, 1):
            z.writestr("xl/worksheets/sheet%d.xml" % i, _sheet_xml(sheets[name]))


def rows_to_dicts(rows):
    """First row is header; return list of dicts with stripped string values."""
    if not rows:
        return []
    header = [str(v).strip() for v in rows[0]]
    out = []
    for row in rows[1:]:
        if not row or all(str(v).strip() == "" for v in row):
            continue
        item = {}
        for i, key in enumerate(header):
            if not key:
                continue
            item[key] = str(row[i]).strip() if i < len(row) else ""
        out.append(item)
    return out
