#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/FirstLookImpPlan.md"
MARKDOWN_OUTPUT="$SCRIPT_DIR/FirstLookImpPlan-embedded.md"
HTML_OUTPUT="$SCRIPT_DIR/FirstLookImpPlan-embedded.html"

if [ ! -f "$SOURCE" ]; then
    echo "Missing source file: $SOURCE" >&2
    exit 1
fi

TMP_MARKDOWN=$(mktemp "${TMPDIR:-/tmp}/first-look-plan-md.XXXXXX")
TMP_HTML=$(mktemp "${TMPDIR:-/tmp}/first-look-plan-html.XXXXXX")
trap 'rm -f "$TMP_MARKDOWN" "$TMP_HTML"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '!'*']('*'.svg)')
            alt=$(printf '%s\n' "$line" | sed -n 's/^!\[\([^]]*\)\](.*)$/\1/p')
            rel_path=$(printf '%s\n' "$line" | sed -n 's/^!\[[^]]*\](\(.*\.svg\))$/\1/p')
            svg_path="$SCRIPT_DIR/$rel_path"

            if [ -n "$alt" ] && [ -n "$rel_path" ] && [ -f "$svg_path" ]; then
                encoded=$(base64 < "$svg_path" | tr -d '\n')
                printf '<img alt="%s" width="260" src="data:image/svg+xml;base64,%s">\n' "$alt" "$encoded" >> "$TMP_MARKDOWN"
            else
                printf '%s\n' "$line" >> "$TMP_MARKDOWN"
            fi
            ;;
        *)
            printf '%s\n' "$line" >> "$TMP_MARKDOWN"
            ;;
    esac
done < "$SOURCE"

python3 - "$TMP_MARKDOWN" "$TMP_HTML" <<'PY'
import html
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
output = Path(sys.argv[2])

html_lines = [
    "<!doctype html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>First Look Implementation Plan</title>",
    "<style>",
    ":root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #111827; background: #f8fafc; }",
    "body { margin: 0; padding: 32px 18px 56px; }",
    ".document { max-width: 920px; margin: 0 auto; background: white; border: 1px solid #e5e7eb; border-radius: 18px; padding: 34px; box-shadow: 0 18px 48px rgba(15, 23, 42, 0.08); }",
    "h1 { font-size: 34px; line-height: 1.15; margin: 0 0 26px; }",
    "h2 { font-size: 24px; line-height: 1.25; margin: 42px 0 16px; padding-top: 10px; border-top: 1px solid #e5e7eb; }",
    "h3 { font-size: 18px; margin: 28px 0 10px; }",
    "p, li { font-size: 16px; line-height: 1.58; }",
    "ul, ol { padding-left: 24px; }",
    "code { background: #f1f5f9; border-radius: 6px; padding: 2px 5px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }",
    "pre { overflow-x: auto; background: #0f172a; color: #e2e8f0; border-radius: 12px; padding: 16px; }",
    "pre code { background: transparent; color: inherit; padding: 0; }",
    "img { display: block; width: 260px; max-width: 100%; height: auto; margin: 16px auto 26px; }",
    "@media (max-width: 640px) { body { padding: 0; } .document { border: 0; border-radius: 0; padding: 24px 18px 40px; } }",
    "</style>",
    "</head>",
    "<body><div class=\"document\">",
]

in_code = False
list_type = None
paragraph = []

def inline(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    return escaped

def flush_paragraph():
    global paragraph
    if paragraph:
        html_lines.append(f"<p>{inline(' '.join(paragraph))}</p>")
        paragraph = []

def close_list():
    global list_type
    if list_type:
        html_lines.append(f"</{list_type}>")
        list_type = None

for raw in source:
    line = raw.rstrip("\n")

    if line.startswith("```"):
        flush_paragraph()
        close_list()
        if in_code:
            html_lines.append("</code></pre>")
            in_code = False
        else:
            html_lines.append("<pre><code>")
            in_code = True
        continue

    if in_code:
        html_lines.append(html.escape(line))
        continue

    if not line.strip():
        flush_paragraph()
        close_list()
        continue

    if line.startswith("<img "):
        flush_paragraph()
        close_list()
        html_lines.append(line)
        continue

    heading = re.match(r"^(#{1,3})\s+(.*)$", line)
    if heading:
        flush_paragraph()
        close_list()
        level = len(heading.group(1))
        html_lines.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
        continue

    bullet = re.match(r"^-\s+(.*)$", line)
    if bullet:
        flush_paragraph()
        if list_type != "ul":
            close_list()
            html_lines.append("<ul>")
            list_type = "ul"
        html_lines.append(f"<li>{inline(bullet.group(1))}</li>")
        continue

    ordered = re.match(r"^\d+\.\s+(.*)$", line)
    if ordered:
        flush_paragraph()
        if list_type != "ol":
            close_list()
            html_lines.append("<ol>")
            list_type = "ol"
        html_lines.append(f"<li>{inline(ordered.group(1))}</li>")
        continue

    close_list()
    paragraph.append(line.strip())

flush_paragraph()
close_list()
if in_code:
    html_lines.append("</code></pre>")
html_lines.extend(["</div></body>", "</html>"])
output.write_text("\n".join(html_lines) + "\n", encoding="utf-8")
PY

mv "$TMP_MARKDOWN" "$MARKDOWN_OUTPUT"
mv "$TMP_HTML" "$HTML_OUTPUT"
trap - EXIT

echo "Wrote $MARKDOWN_OUTPUT"
echo "Wrote $HTML_OUTPUT"
