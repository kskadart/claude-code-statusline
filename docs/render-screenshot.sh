#!/bin/bash
# Regenerate docs/screenshot.html (and, with --render, docs/screenshot.png)
# from the *real* output of ../statusline.sh on a few built-in fixtures.
#
# Safety: runs statusline.sh with tests/stubs (fake `security`/`curl`) first
# on PATH, and HOME / CLAUDE_STATUSLINE_CACHE_DIR pointed at a temp dir, so
# it never touches the real Keychain, network, or ~/.claude/cache. All
# fixtures below embed rate_limits directly, so the 5h/w fallback path never
# actually fires for those segments -- it's there only as defense in depth.
# The `security`/`curl` stubs do fire for fixture A, on purpose: it serves a
# canned usage-endpoint response through the curl stub so its model segment
# can show the per-model weekly-usage part (that part has no stdin field to
# embed; see CLAUDE_STATUSLINE_MODEL_LIMIT in README.md). The stubs are
# disabled (via CLAUDE_STATUSLINE_MODEL_LIMIT=0) for fixtures B and C, so
# their model segments don't depend on fixture A's cached response.
#
# Usage:
#   docs/render-screenshot.sh            # writes docs/screenshot.html only
#   docs/render-screenshot.sh --render   # also renders docs/screenshot.png,
#                                         # via a local headless Chrome/Chromium
#                                         # plus a python3 crop step for a
#                                         # symmetric top/bottom margin
#                                         # (falls back to the uncropped
#                                         # tall render if python3 is absent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUSLINE="$REPO_ROOT/statusline.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
FAKE_HOME="$WORK_DIR/home"
CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$FAKE_HOME" "$CACHE_DIR"

now=$(date +%s)

render_line() {
    # $1 = fixture JSON on stdin (via file), prints raw (ANSI) statusline
    # output. $2 = optional usage-endpoint response file, served through the
    # curl stub for this render only, so the model segment's per-model
    # weekly-usage part can be shown (it has no stdin field of its own).
    # When $2 is omitted, the per-model fetch is disabled outright for this
    # render (rather than left to fall through to whatever is in the shared
    # cache dir), so fixtures B/C never depend on fixture A's cached
    # response.
    local fixture="$1" usage_response="${2:-}"
    local model_limit=1
    if [ -z "$usage_response" ]; then
        model_limit=0
    fi
    PATH="$STUBS_DIR:$PATH" HOME="$FAKE_HOME" CLAUDE_STATUSLINE_CACHE_DIR="$CACHE_DIR" \
        STUB_CURL_RESPONSE_FILE="$usage_response" STUB_SECURITY_TOKEN="stub-token" \
        CLAUDE_STATUSLINE_MODEL_LIMIT="$model_limit" \
        "$STATUSLINE" < "$fixture"
}

# --- Fixture A: the plain README example -----------------------------------
# Offsets carry a safety margin (30s / 30min) past the exact hour/day
# boundary so a second of wall-clock drift between computing `now` here and
# statusline.sh reading its own `NOW` can never flip the rendered bucket
# (XhYm and XdYh formats truncate, they don't show seconds/minutes below
# their own granularity, so a small margin makes the text stable). This
# must keep matching the "Example" block in README.md.
fixture_a="$WORK_DIR/a.json"
jq -n --argjson five_reset $((now + 1*3600 + 39*60 + 30)) --argjson week_reset $((now + 3*86400 + 6*3600 + 1800)) '{
  workspace: { current_dir: "/home/user/.claude" },
  model: { id: "claude-fable-5-1", display_name: "Fable 5.1" },
  cost: { total_cost_usd: 0, total_duration_ms: 6000, total_lines_added: 0, total_lines_removed: 0 },
  context_window: { used_percentage: 0 },
  rate_limits: {
    five_hour: { used_percentage: 23, resets_at: $five_reset },
    seven_day: { used_percentage: 37, resets_at: $week_reset }
  }
}' > "$fixture_a"

# Usage-endpoint response for fixture A's model segment: same shape as
# tests/fixtures/usage-limits.json (a weekly_scoped row for "Fable"), but
# with resets_at generated from `now` so the screenshot shows a realistic
# countdown instead of a multi-decade one. Served through the curl stub only
# while rendering fixture A (see render_line's $2 above).
fixture_a_usage="$WORK_DIR/a-usage.json"
jq -n --argjson model_reset $((now + 2*86400 + 21*3600 + 1800)) '{
  five_hour: { utilization: 23, resets_at: "2099-01-01T00:00:00.000000+00:00" },
  seven_day: { utilization: 37, resets_at: "2099-01-01T00:00:00.000000+00:00" },
  limits: [
    {
      kind: "weekly_scoped", group: "weekly", percent: 80, severity: "warning", is_active: true,
      resets_at: (($model_reset | gmtime | strftime("%Y-%m-%dT%H:%M:%S")) + ".000000+00:00"),
      scope: { model: { display_name: "Fable" }, surface: null }
    }
  ]
}' > "$fixture_a_usage"

# --- Fixture B: with the +add/-del lines segment ----------------------------
# Same margin reasoning as fixture A; must keep matching README.md.
fixture_b="$WORK_DIR/b.json"
jq -n --argjson five_reset $((now + 4*3600 + 51*60 + 30)) --argjson week_reset $((now + 6*86400 + 22*3600 + 1800)) '{
  workspace: { current_dir: "/home/user/projects/myproj" },
  model: { id: "claude-sonnet-5", display_name: "Sonnet 5" },
  cost: { total_cost_usd: 0.42, total_duration_ms: 192000, total_lines_added: 12, total_lines_removed: 3 },
  context_window: { used_percentage: 18 },
  rate_limits: {
    five_hour: { used_percentage: 5, resets_at: $five_reset },
    seven_day: { used_percentage: 9, resets_at: $week_reset }
  }
}' > "$fixture_b"

# --- Fixture C: high usage, to show yellow/red thresholds -------------------
fixture_c="$WORK_DIR/c.json"
jq -n --argjson five_reset $((now + 45*60)) --argjson week_reset $((now + 2*86400 + 5*3600)) '{
  workspace: { current_dir: "/home/user/projects/bigproject" },
  model: { id: "claude-opus-5", display_name: "Opus 5" },
  cost: { total_cost_usd: 2.15, total_duration_ms: 932000, total_lines_added: 0, total_lines_removed: 0 },
  context_window: { used_percentage: 91 },
  rate_limits: {
    five_hour: { used_percentage: 75, resets_at: $five_reset },
    seven_day: { used_percentage: 40, resets_at: $week_reset }
  }
}' > "$fixture_c"

raw_a=$(render_line "$fixture_a" "$fixture_a_usage")
raw_b=$(render_line "$fixture_b")
raw_c=$(render_line "$fixture_c")

# --- ANSI SGR -> inline-styled HTML spans -----------------------------------
# Only the codes statusline.sh actually emits are handled.
ansi_to_html() {
    perl -pe '
        s/\e\[36m/<span style="color:#00cdcd">/g;             # cyan   (dir)
        s/\e\[90m/<span style="color:#7f7f7f">/g;              # gray   (separators)
        s/\e\[38;5;108m/<span style="color:#87af87">/g;        # sage   (duration)
        s/\e\[35m/<span style="color:#cd00cd">/g;              # magenta (model)
        s/\e\[32m/<span style="color:#00cd00">/g;              # green  (+lines / low pct)
        s/\e\[33m/<span style="color:#cdcd00">/g;              # yellow (cost / mid pct)
        s/\e\[31m/<span style="color:#cd0000">/g;              # red    (-lines / high pct)
        s/\e\[38;5;208m/<span style="color:#ff8700">/g;        # orange (clock)
        s/\e\[0m/<\/span>/g;
    '
}

html_a=$(printf '%s' "$raw_a" | ansi_to_html)
html_b=$(printf '%s' "$raw_b" | ansi_to_html)
html_c=$(printf '%s' "$raw_c" | ansi_to_html)

# Build a 3-line "input box" mock, all three lines the same visible width
# (box-drawing corners + dashes on top/bottom, "| > ... |" in the middle),
# so the right edge lines up regardless of font/markup quirks.
BOX_INNER=70
dashes=$(printf -- '-%.0s' $(seq 1 "$BOX_INNER"))
dashes=${dashes//-/$'\xe2\x94\x80'} # U+2500 BOX DRAWINGS LIGHT HORIZONTAL
box_top="$(printf '\xe2\x95\xad')${dashes}$(printf '\xe2\x95\xae')"      # ╭───╮
box_bottom="$(printf '\xe2\x95\xb0')${dashes}$(printf '\xe2\x95\xaf')"  # ╰───╯
caret_visible="> "
caret_pad_len=$((BOX_INNER - ${#caret_visible} - 1))
caret_pad=$(printf ' %.0s' $(seq 1 "$caret_pad_len"))
box_middle="$(printf '\xe2\x94\x82') <span class=\"caret\">&gt;</span> ${caret_pad}$(printf '\xe2\x94\x82')"
prompt_box="${box_top}
${box_middle}
${box_bottom}"

OUT_HTML="$SCRIPT_DIR/screenshot.html"
OUT_PNG="$SCRIPT_DIR/screenshot.png"

cat > "$OUT_HTML" <<HTML
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  html, body {
    margin: 0;
    padding: 0;
    background: #1e1e1e;
  }
  body {
    width: 900px;
    padding: 24px;
    box-sizing: border-box;
    font-family: Menlo, Monaco, "SF Mono", Consolas, monospace;
    font-size: 13px;
    color: #d4d4d4;
  }
  .prompt {
    white-space: pre;
    color: #6a6a6a;
    line-height: 1.5;
  }
  .statusline {
    white-space: pre;
    padding-left: 2ch;
    margin: 0 0 22px 0;
    line-height: 1.5;
  }
  .prompt .caret {
    color: #d4d4d4;
  }
</style>
</head>
<body>

<pre class="prompt">${prompt_box}</pre>
<pre class="statusline">${html_a}</pre>

<pre class="prompt">${prompt_box}</pre>
<pre class="statusline">${html_b}</pre>

<pre class="prompt">${prompt_box}</pre>
<pre class="statusline">${html_c}</pre>

</body>
</html>
HTML

echo "Wrote $OUT_HTML"

if [ "${1:-}" = "--render" ]; then
    CHROME_BIN="${CHROME_BIN:-}"
    if [ -z "$CHROME_BIN" ]; then
        for candidate in \
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
            "/Applications/Chromium.app/Contents/MacOS/Chromium" \
            "$(command -v google-chrome 2>/dev/null)" \
            "$(command -v chromium 2>/dev/null)" \
            "$(command -v chromium-browser 2>/dev/null)"; do
            if [ -n "$candidate" ] && [ -x "$candidate" ]; then
                CHROME_BIN="$candidate"
                break
            fi
        done
    fi

    if [ -z "$CHROME_BIN" ]; then
        echo "No local Chrome/Chromium found for --render. Options:" >&2
        echo "  - install Google Chrome or Chromium, or set CHROME_BIN=/path/to/chrome" >&2
        echo "  - use a Playwright MCP tool (browser_navigate + browser_take_screenshot) on file://$OUT_HTML" >&2
        exit 1
    fi

    # Render tall (this page is far shorter than 900 CSS px) rather than
    # tuning --window-size down to the content height: headless Chrome's
    # --screenshot clips at some heights *below* the actual content height
    # for this page (observed: window heights under ~440 silently drop
    # whole lines, not just partial pixels -- a Chromium viewport/painting
    # quirk with a <pre>-heavy page at small heights, not a CSS bug here).
    # Rendering tall avoids that clipping entirely; the Python step below
    # then trims the image to a symmetric top/bottom margin by measuring
    # the actual non-background pixel bounds, so the margin tuning never
    # depends on that flaky small-viewport behavior.
    "$CHROME_BIN" --headless=new --screenshot="$OUT_PNG" \
        --window-size=900,900 --force-device-scale-factor=2 \
        --default-background-color=00000000 \
        "file://$OUT_HTML"
    echo "Wrote $OUT_PNG (tall)"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$OUT_PNG" <<'PY'
import struct, sys, zlib

path = sys.argv[1]


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    pos = 8
    width = height = None
    idat = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height = struct.unpack(">II", chunk[:8])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 8 + length + 4
    raw = zlib.decompress(idat)
    bpp = 3
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    idx = 0
    for _ in range(height):
        ft = raw[idx]
        idx += 1
        line = bytearray(raw[idx:idx + stride])
        idx += stride
        if ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) // 2)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        rows.append(bytes(line))
        prev = line
    return width, rows


def write_png(path, width, rows):
    def chunk(tag, chunk_data):
        return (
            struct.pack(">I", len(chunk_data))
            + tag
            + chunk_data
            + struct.pack(">I", zlib.crc32(tag + chunk_data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, len(rows), 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + row for row in rows)  # filter type 0 (None) per row
    idat = zlib.compress(raw, 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


width, rows = read_png(path)

bg = (30, 30, 30)  # #1e1e1e


def row_is_bg(row):
    for i in range(0, len(row), 3):
        if max(abs(row[i] - bg[0]), abs(row[i + 1] - bg[1]), abs(row[i + 2] - bg[2])) > 4:
            return False
    return True


first = last = None
for y, row in enumerate(rows):
    if not row_is_bg(row):
        if first is None:
            first = y
        last = y

if first is None:
    sys.exit("crop_screenshot: page looks empty, refusing to touch " + path)

# Bottom margin == top margin (both equal to `first`, the device-px offset
# of the first non-background row), then drop the unused tall canvas below.
crop_height = min(last + 1 + first, len(rows))
write_png(path, width, rows[:crop_height])
print(f"Cropped {path} to {width}x{crop_height} (top margin == bottom margin == {first}px device)")
PY
    else
        echo "python3 not found: skipping the symmetric-margin crop step," >&2
        echo "$OUT_PNG is the full 900px-tall render instead." >&2
    fi
fi
