#!/usr/bin/env python3
"""Convert power_results.md into one self-contained HTML file.

Images are embedded as base64 data URIs, so the HTML can be sent or opened on its own.
Only the Markdown used by power_results.md is supported: headings, tables, images,
bold, italic, inline code, fenced code blocks and links.

Usage: python make_report_html.py [input.md] [output.html]
"""

import base64
import html
import mimetypes
import re
import sys
from pathlib import Path

CSS = """
:root { --bg:#fff; --fg:#1d2327; --muted:#5b6770; --line:#d5dbe0; --head:#eef2f5; --accent:#0077c8; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#14181b; --fg:#e4e8eb; --muted:#9aa5ad; --line:#2d363c; --head:#1d2429; --accent:#5ab0ee; }
}
body { background:var(--bg); color:var(--fg); font:16px/1.6 system-ui,"Segoe UI","Microsoft YaHei",sans-serif;
       max-width:1000px; margin:0 auto; padding:24px 16px 64px; }
h1 { font-size:1.7rem; margin:0 0 .6em; }
h2 { font-size:1.35rem; margin:2em 0 .6em; padding-top:.6em; border-top:1px solid var(--line); }
h3 { font-size:1.1rem; margin:1.8em 0 .5em; }
table { border-collapse:collapse; width:100%; margin:1em 0; display:block; overflow-x:auto; }
th, td { border:1px solid var(--line); padding:6px 10px; text-align:left; vertical-align:top; }
th { background:var(--head); }
th:first-child, td:first-child { white-space:nowrap; }
code { background:var(--head); padding:1px 5px; border-radius:3px; font-size:.9em; }
img { max-width:100%; height:auto; border:1px solid var(--line); border-radius:4px; }
p.cap { color:var(--muted); font-size:.9em; margin:.3em 0 1em; }
a { color:var(--accent); }
pre { background:var(--head); padding:10px 14px; border-radius:4px; overflow-x:auto; }
pre code { padding:0; background:none; }
"""


def inline(text: str) -> str:
    """Render the inline Markdown used in the report."""
    codes: list[str] = []

    def stash(match: re.Match) -> str:
        codes.append(f"<code>{html.escape(match.group(1))}</code>")
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)", r"<em>\1</em>", text)
    # links to another report page point at its generated HTML, not at the Markdown source
    text = re.sub(r"\[([^\]]+)\]\(([^)]+?)(?:\.md)?\)",
                  lambda m: f'<a href="{m.group(2)}{".html" if m.group(0).endswith(".md)") else ""}">{m.group(1)}</a>',
                  text)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], text)


def embed(src: str, base: Path) -> str:
    """Return a data URI for a local image, or the source unchanged if it is not a local file."""
    path = base / src
    if not path.is_file():
        return src
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def table(rows: list[str]) -> str:
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    head, body = cells[0], cells[2:]
    out = ["<table>", "<thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead>", "<tbody>"]
    out += ["<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>" for row in body]
    return "\n".join(out + ["</tbody>", "</table>"])


def convert(md: str, base: Path) -> tuple[str, str]:
    lines = md.splitlines()
    out: list[str] = []
    title = "Report"
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
        elif line.startswith("```"):
            i += 1
            code = []
            while i < len(lines) and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>" + html.escape(chr(10).join(code)) + "</code></pre>")
        elif line.startswith("|"):
            block = []
            while i < len(lines) and lines[i].startswith("|"):
                block.append(lines[i])
                i += 1
            out.append(table(block))
        elif m := re.match(r"(#{1,3}) (.+)", line):
            level = len(m.group(1))
            if level == 1:
                title = m.group(2)
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            i += 1
        elif m := re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", line.strip()):
            out.append(f'<p><img alt="{html.escape(m.group(1))}" src="{embed(m.group(2), base)}"></p>')
            i += 1
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not lines[i].startswith(("|", "#", "![")):
                para.append(lines[i].strip())
                i += 1
            text = " ".join(para)
            cls = ' class="cap"' if re.fullmatch(r"\*(?:图|Figure) \d+[:：].*\*", text) else ""
            out.append(f"<p{cls}>{inline(text)}</p>")
    return title, "\n".join(out)


def main() -> None:
    src = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("power_results.md"))
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".html")
    text = src.read_text(encoding="utf-8")
    title, body = convert(text, src.parent)
    # the language switch link ("中文") must not make an English page look Chinese
    lang = "zh-CN" if len(re.findall(r"[一-鿿]", text)) > 20 else "en"
    dst.write_text(
        f'<!doctype html>\n<html lang="{lang}">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{html.escape(title)}</title>\n<style>{CSS}</style>\n</head>\n<body>\n{body}\n</body>\n</html>\n",
        encoding="utf-8",
    )
    print(f"{dst} ({dst.stat().st_size / 1048576:.1f} MB)")


if __name__ == "__main__":
    main()
