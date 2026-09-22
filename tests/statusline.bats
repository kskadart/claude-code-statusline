#!/usr/bin/env bats
# Tests for statusline.sh.
#
# Safety: every test prepends tests/stubs (fake `security` and `curl`) to
# PATH, so the script can never read the real macOS Keychain or make a real
# network request, even when this suite is run on a machine that has a real
# Claude Code Keychain entry. HOME and CLAUDE_STATUSLINE_CACHE_DIR are also
# redirected to per-test temp directories, so the real ~/.claude/cache is
# never touched.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../statusline.sh"
STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"

setup() {
    TEST_HOME="$BATS_TEST_TMPDIR/home"
    TEST_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$TEST_HOME"
    # Intentionally do NOT pre-create TEST_CACHE_DIR: the script must
    # mkdir -p it itself, and several tests assert it stays absent.

    export HOME="$TEST_HOME"
    export CLAUDE_STATUSLINE_CACHE_DIR="$TEST_CACHE_DIR"
    export PATH="$STUBS_DIR:$PATH"

    unset STUB_SECURITY_TOKEN
    unset STUB_CURL_RESPONSE_FILE
    export STUB_CURL_CALLED_MARKER="$BATS_TEST_TMPDIR/curl-called"
    rm -f "$STUB_CURL_CALLED_MARKER"

    CACHE_FILE="$TEST_CACHE_DIR/statusline-ratelimit.json"
}

# Strip ANSI SGR color codes from a string. Works with the perl available on
# both macOS and Linux GitHub Actions runners (avoids GNU-vs-BSD `sed -e`
# escape differences for \x1b).
strip_ansi() {
    printf '%s' "$1" | perl -pe 's/\e\[[0-9;]*m//g'
}

# Run statusline.sh with the given fixture file on stdin, in an explicit,
# minimal environment (PATH/HOME/CLAUDE_STATUSLINE_CACHE_DIR threaded through
# as positional args, not string-interpolated, to avoid quoting issues).
run_statusline() {
    local fixture="$1"
    run bash -c 'PATH="$1" HOME="$2" CLAUDE_STATUSLINE_CACHE_DIR="$3" "$4" < "$5"' _ \
        "$PATH" "$HOME" "$CLAUDE_STATUSLINE_CACHE_DIR" "$SCRIPT" "$fixture"
}

# Build a fixture with rate_limits.*.resets_at set to now+offset seconds,
# written into a fresh file under BATS_TEST_TMPDIR. Only patches the keys
# that are present in the source fixture.
with_resets_at() {
    local src="$1" out="$2" five_offset="$3" week_offset="${4:-}"
    local now five_at week_at
    now=$(date +%s)
    five_at=$((now + five_offset))
    if [ -n "$week_offset" ]; then
        week_at=$((now + week_offset))
        jq --argjson five "$five_at" --argjson week "$week_at" \
            '.rate_limits.five_hour.resets_at = $five | .rate_limits.seven_day.resets_at = $week' \
            "$src" > "$out"
    else
        jq --argjson five "$five_at" \
            '.rate_limits.five_hour.resets_at = $five' \
            "$src" > "$out"
    fi
}

# Cross-platform "set this file's mtime to N seconds ago" (BSD `date -v` on
# macOS, GNU `date -d` on Linux both accept the same `touch -t` timestamp
# format: [[CC]YY]MMDDhhmm.ss).
age_file() {
    local file="$1" seconds_ago="$2" ts
    ts=$(date -v-"${seconds_ago}"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-${seconds_ago} seconds" +%Y%m%d%H%M.%S)
    touch -t "$ts" "$file"
}

file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

@test "full render with rate_limits: all segments present, correct order, no +0/-0" {
    local fixture="$BATS_TEST_TMPDIR/full.json"
    with_resets_at "$FIXTURES_DIR/full.json" "$fixture" 7200 100000

    # This test's own point is "stdin rate_limits means no fallback fetch at
    # all"; disable the (separate) per-model weekly-limit fetch so it
    # doesn't touch the cache dir/curl either, which would otherwise make
    # the "no curl call" / "no cache dir" assertions below false even though
    # stdin rate_limits were used correctly.
    export CLAUDE_STATUSLINE_MODEL_LIMIT=0
    run_statusline "$fixture"
    [ "$status" -eq 0 ]

    clean=$(strip_ansi "$output")
    echo "clean: $clean" >&3

    [[ "$clean" == *"myproj"* ]]
    [[ "$clean" == *"Fable 5.1"* ]]
    [[ "$clean" == *'$1.23'* ]]
    [[ "$clean" == *"ctx:42%"* ]]
    [[ "$clean" == *"5h:23%"* ]]
    [[ "$clean" == *"w:37%"* ]]
    [[ "$clean" == *"1h1m"* ]]
    [[ "$clean" =~ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
    [[ "$clean" != *"+0/-0"* ]]

    # Segment order via a single regex over the whole line.
    [[ "$clean" =~ myproj\ \|\ Fable\ 5\.1\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%.*\ \|\ w:37%.*\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]

    # No fallback path should have been taken: rate_limits came from stdin.
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
    [ ! -d "$TEST_CACHE_DIR" ]
}

@test "model segment (display_name) is shown as the 2nd segment, right after dir" {
    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Fable 5.1 | "* ]]
    [[ "$output" == *$'\033[35mFable 5.1'* ]]
}

@test "model segment falls back to model.id when display_name is absent" {
    run_statusline "$FIXTURES_DIR/model-id-only.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "modelid | claude-sonnet-5 | "* ]]
}

@test "no model field: model segment is hidden entirely (exact expected line)" {
    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" =~ ^nolimits\ \|\ \$0\.01\ \|\ ctx:1%\ \|\ 5s\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "model.display_name is \"\" falls back to model.id" {
    local fixture="$BATS_TEST_TMPDIR/model-empty-display.json"
    jq '.model = {display_name: "", id: "claude-sonnet-5"}' "$FIXTURES_DIR/full.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | claude-sonnet-5 | "* ]]
}

@test "model is null: segment hidden" {
    local fixture="$BATS_TEST_TMPDIR/model-null.json"
    jq '.model = null' "$FIXTURES_DIR/full.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | \$1.23 | "* ]]
}

@test "lines segment shown as +12/-3 when lines were added and removed" {
    run_statusline "$FIXTURES_DIR/lines.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"+12"* ]]
    [[ "$clean" == *"-3"* ]]
    [[ "$clean" =~ \+12/-3 ]] || [[ "$clean" == *"+12"*"/"*"-3"* ]]
}

@test "current_dir == HOME renders as ~" {
    local fixture="$BATS_TEST_TMPDIR/home-dir.json"
    jq --arg home "$HOME" '.workspace.current_dir = $home' "$FIXTURES_DIR/home-dir.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "~ |"* ]]
}

@test "resets_at in the future (+3750s) formats as (1h2m)" {
    local fixture="$BATS_TEST_TMPDIR/resets-future.json"
    with_resets_at "$FIXTURES_DIR/resets-template.json" "$fixture" 3750

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"(1h2m)"* ]]
}

@test "resets_at in the past formats as (now)" {
    local fixture="$BATS_TEST_TMPDIR/resets-past.json"
    with_resets_at "$FIXTURES_DIR/resets-template.json" "$fixture" -120

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"(now)"* ]]
}

@test "resets_at far in the future (+91800s) formats as (1d1h)" {
    local fixture="$BATS_TEST_TMPDIR/resets-far.json"
    # 91800s = 1d1h30m, a 30-minute margin so a second's jitter between
    # computing the offset here and NOW inside statusline.sh never flips
    # the hour bucket (91800 was 90000 = exactly 1d1h, which flapped to
    # 1d0h roughly 1 run in 10 under a slow test host).
    with_resets_at "$FIXTURES_DIR/resets-template.json" "$fixture" 91800

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"(1d1h)"* ]]
}

@test "no rate_limits, no cache, security returns nothing: 5h/7d absent, no curl, no cache" {
    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" != *"5h:"* ]]
    [[ "$clean" != *"w:"* ]]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
    [ ! -f "$CACHE_FILE" ]
}

@test "fallback via curl: renders 5h:56% and w:12%, cache created with mode 600" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-usage.json"

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"5h:56%"* ]]
    [[ "$clean" == *"w:12%"* ]]
    # resets_at is 2099-01-01, far enough out to always render as "XdYh".
    [[ "$clean" =~ \([0-9]+d[0-9]+h\) ]]

    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ -f "$CACHE_FILE" ]
    [ "$(file_mode "$CACHE_FILE")" = "600" ]
}

@test "fresh cache (<60s old): curl is not called, values come from cache" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-usage.json"

    mkdir -p "$TEST_CACHE_DIR"
    cp "$FIXTURES_DIR/fallback-usage.json" "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"
    # mtime defaults to "now", well within the 60s freshness window.

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"5h:56%"* ]]
    [[ "$clean" == *"w:12%"* ]]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
}

@test "stale cache (>60s old): curl is called and cache is refreshed" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-usage.json"

    mkdir -p "$TEST_CACHE_DIR"
    printf '{"five_hour":{"utilization":1,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":2,"resets_at":"2099-01-01T00:00:00.000000+00:00"}}' > "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"
    age_file "$CACHE_FILE" 120

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [[ "$clean" == *"5h:56%"* ]]
    [[ "$clean" == *"w:12%"* ]]
}

@test "CLAUDE_STATUSLINE_CACHE_DIR is honored: cache appears exactly there" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-usage.json"

    local alt_dir="$BATS_TEST_TMPDIR/alt-cache"
    export CLAUDE_STATUSLINE_CACHE_DIR="$alt_dir"

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    [ -f "$alt_dir/statusline-ratelimit.json" ]
    [ ! -f "$CACHE_FILE" ]
}

@test "invalid curl response: no cache written, .tmp cleaned up, script still exits 0" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-invalid.json"

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" != *"5h:"* ]]
    [[ "$clean" != *"w:"* ]]
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ ! -f "$CACHE_FILE" ]
    [ ! -f "$CACHE_FILE.tmp" ]
    [ -n "$clean" ]
}

@test "model weekly usage: shown after model name, general w: still comes from stdin" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Fable 5.1 80% ("* ]]
    # The general weekly segment still comes from stdin's rate_limits.seven_day
    # (37%), not from the usage endpoint's seven_day.utilization (12) or its
    # weekly_all row (44).
    [[ "$clean" == *" | w:37% ("* ]]
    [[ "$output" == *$'\033[33m80%'* ]]
}

@test "model weekly usage: no matching weekly_scoped row -> name only" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    # Sonnet now has its own weekly_scoped row in the fixture (see the
    # "model weekly usage: id-only model matches by id-contains" test), so
    # use a model with no matching row at all to keep this a true no-match
    # case.
    local fixture="$BATS_TEST_TMPDIR/full-haiku.json"
    jq '.model = {id: "claude-haiku-4-5", display_name: "Haiku 4.5"}' "$FIXTURES_DIR/full.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Haiku 4.5 | \$1.23 | "* ]]
    # Proves the fetch path actually ran (and simply found no match), not
    # that it was skipped.
    [ -f "$STUB_CURL_CALLED_MARKER" ]
}

@test "model weekly usage: id-only model matches by id-contains" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    # model.display_name is absent, so MODEL_ID drives both MODEL_NAME and
    # the id-contains matching branch. This is also the regression case for
    # the MODEL_TSV parsing bug (F1): before the fix, a leading tab in the
    # jq @tsv output (empty display_name field) was stripped by IFS-based
    # `read`, which shifted model.id into MODEL_DISPLAY and left MODEL_ID
    # empty -- the id-contains match below would never have fired.
    run_statusline "$FIXTURES_DIR/model-id-only.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "modelid | claude-sonnet-5 42% ("* ]]
}

@test "model weekly usage: curl returns nothing -> name only, still exits 0" {
    export STUB_SECURITY_TOKEN="stub-token"
    # STUB_CURL_RESPONSE_FILE intentionally left unset: the curl stub is
    # invoked (a token is available) but prints nothing, like a network
    # failure or empty response.

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Fable 5.1 | \$1.23 | "* ]]
    # Proves the fetch path actually ran (and got an empty response), not
    # that it was skipped.
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ ! -f "$CACHE_FILE" ]
}

@test "security unavailable: no fetch attempted, model name only" {
    # Build a PATH where no `security` executable can be found at all
    # (simulating Linux, or any host without the macOS Keychain tool),
    # while jq/date/stat/perl etc. stay resolvable. Some hosts co-locate
    # `security` with other required tools (e.g. macOS's /usr/bin holds
    # both `security` and `jq`), so a directory that provides `security` is
    # replaced with a symlink farm of everything else it provides, rather
    # than dropped from PATH outright.
    local no_security_bin="$BATS_TEST_TMPDIR/no-security-bin"
    mkdir -p "$no_security_bin"
    cp "$STUBS_DIR/curl" "$no_security_bin/curl"
    chmod +x "$no_security_bin/curl"

    local orig_path="${PATH#"$STUBS_DIR":}"
    local new_path="$no_security_bin"
    local saved_ifs="$IFS"
    local dir
    IFS=':'
    for dir in $orig_path; do
        IFS="$saved_ifs"
        if [ -n "$dir" ] && [ -x "$dir/security" ]; then
            local shadow="$BATS_TEST_TMPDIR/shadow${dir//\//_}"
            mkdir -p "$shadow"
            local f base
            for f in "$dir"/*; do
                [ -f "$f" ] && [ -x "$f" ] || continue
                base="${f##*/}"
                [ "$base" = "security" ] && continue
                ln -sf "$f" "$shadow/$base" 2>/dev/null
            done
            new_path="$new_path:$shadow"
        elif [ -n "$dir" ]; then
            new_path="$new_path:$dir"
        fi
        IFS=':'
    done
    IFS="$saved_ifs"

    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"
    export PATH="$new_path"

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Fable 5.1 | "* ]]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
}

@test "CLAUDE_STATUSLINE_MODEL_LIMIT=0: name only, curl never called" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"
    export CLAUDE_STATUSLINE_MODEL_LIMIT=0

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Fable 5.1 | \$1.23 | "* ]]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
}

@test "model weekly usage: cache is reused within TTL, curl called once" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ -f "$CACHE_FILE" ]
    [ "$(file_mode "$CACHE_FILE")" = "600" ]

    # Simulate "curl was not called again": delete the marker, then re-run
    # within the 60s TTL and assert it stays absent (values still come from
    # the now-fresh cache, not a second network round trip).
    rm -f "$STUB_CURL_CALLED_MARKER"

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | Fable 5.1 80% ("* ]]
}

@test "high ctx (95%) is colored red before rendering" {
    run_statusline "$FIXTURES_DIR/high-ctx.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[31mctx:95%'* ]]
}

@test "default cache dir (no CLAUDE_STATUSLINE_CACHE_DIR): writes under \$HOME/.claude/cache, mode 600" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-usage.json"
    unset CLAUDE_STATUSLINE_CACHE_DIR
    # HOME is still the per-test temp dir from setup(), so this never
    # touches the real ~/.claude/cache.

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]

    local default_cache="$HOME/.claude/cache/statusline-ratelimit.json"
    [ -f "$default_cache" ]
    [ "$(file_mode "$default_cache")" = "600" ]
}

@test "ctx color thresholds: <70 green, 70-89 yellow, >=90 red" {
    local base="$FIXTURES_DIR/minimal.json"
    for pair in "69:32" "70:33" "89:33" "90:31"; do
        local pct="${pair%%:*}"
        local color="${pair##*:}"
        local fixture="$BATS_TEST_TMPDIR/ctx-$pct.json"
        jq --argjson pct "$pct" '.context_window.used_percentage = $pct' "$base" > "$fixture"

        run_statusline "$fixture"
        [ "$status" -eq 0 ]
        local expected
        expected=$'\033['"$color"'mctx:'"$pct"'%'
        [[ "$output" == *"$expected"* ]]
    done
}

@test "locale independence: a comma-decimal locale still renders dot-decimal numbers" {
    local loc
    loc=$(locale -a 2>/dev/null | grep -im1 -E 'de_DE\.utf-?8|ru_RU\.utf-?8') || true
    if [ -z "$loc" ]; then
        skip "no comma-decimal locale on this machine"
    fi

    local fixture="$BATS_TEST_TMPDIR/locale-full.json"
    with_resets_at "$FIXTURES_DIR/full.json" "$fixture" 7200 100000

    run --separate-stderr bash -c \
        'LC_ALL="$1" PATH="$2" HOME="$3" CLAUDE_STATUSLINE_CACHE_DIR="$4" "$5" < "$6"' _ \
        "$loc" "$PATH" "$HOME" "$CLAUDE_STATUSLINE_CACHE_DIR" "$SCRIPT" "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *'$1.23'* ]]
    [[ "$clean" == *"5h:23%"* ]]
    [[ "$clean" == *"w:37%"* ]]
    [ -z "$stderr" ]
}
