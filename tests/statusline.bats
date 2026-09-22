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

@test "full render with rate_limits: all segments present, correct order, no model name anywhere" {
    local fixture="$BATS_TEST_TMPDIR/full.json"
    with_resets_at "$FIXTURES_DIR/full.json" "$fixture" 7200 100000

    # This test's own point is "stdin rate_limits means no fallback fetch at
    # all"; disable the (separate) per-model weekly-limit fetch so it
    # doesn't touch the cache dir/curl either, which would otherwise make
    # the "no curl call" / "no cache dir" assertions below false even though
    # stdin rate_limits were used correctly. It also proves the model name
    # (full.json has one) is never rendered anywhere on the line.
    export CLAUDE_STATUSLINE_MODEL_LIMIT=0
    run_statusline "$fixture"
    [ "$status" -eq 0 ]

    clean=$(strip_ansi "$output")
    echo "clean: $clean" >&3

    [[ "$clean" == *"myproj"* ]]
    [[ "$clean" == *'$1.23'* ]]
    [[ "$clean" == *"ctx:42%"* ]]
    [[ "$clean" == *"5h:23%"* ]]
    [[ "$clean" == *"w:37%"* ]]
    [[ "$clean" == *"1h1m"* ]]
    [[ "$clean" =~ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
    [[ "$clean" != *"+0/-0"* ]]
    [[ "$clean" != *"Fable"* ]]

    # Segment order via a single anchored regex over the whole stripped
    # line (chained-literal globs sharing a " | " boundary can silently
    # never match -- see the CI failure this replaced). No model segment
    # anywhere: dir is followed directly by cost.
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \([0-9a-z]+\)\ \|\ w:37%\ \([0-9a-z]+\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]

    # No fallback path should have been taken: rate_limits came from stdin.
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
    [ ! -d "$TEST_CACHE_DIR" ]
}

@test "no model field: exact expected line" {
    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" =~ ^nolimits\ \|\ \$0\.01\ \|\ ctx:1%\ \|\ 5s\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "model.display_name is \"\" falls back to model.id for weekly-usage matching (via w:)" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    local fixture="$BATS_TEST_TMPDIR/model-empty-display.json"
    jq '.model = {display_name: "", id: "claude-sonnet-5"}' "$FIXTURES_DIR/full.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    # MODEL_DISPLAY is "" so matching falls back to the id-contains branch
    # on MODEL_ID ("claude-sonnet-5"), picking usage-limits.json's Sonnet
    # weekly_scoped row (42%); no model name is rendered anywhere.
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)/42%\ \([0-9]+d[0-9]+h\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "model is null: no / in w: (no per-model match attempted), no curl call" {
    local fixture="$BATS_TEST_TMPDIR/model-null.json"
    jq '.model = null' "$FIXTURES_DIR/full.json" > "$fixture"

    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == "myproj | \$1.23 | "* ]]
    [[ "$clean" != *"w:37%/"* ]]
    # MODEL_NAME is empty, so NEED_MODEL_LIMIT is false; full.json already
    # carries stdin rate_limits, so NEED_FALLBACK is also false -- no reason
    # to call curl at all.
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
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

@test "failed fetch leaves a .fail marker (mode 600) that blocks retries within the TTL" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-invalid.json"

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ -f "$CACHE_FILE.fail" ]
    [ "$(file_mode "$CACHE_FILE.fail")" = "600" ]

    # Re-run within the TTL: the negative cache should block a retry, so
    # curl is not invoked again.
    rm -f "$STUB_CURL_CALLED_MARKER"

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
}

@test "a successful fetch clears a pre-existing .fail marker" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/fallback-usage.json"

    mkdir -p "$TEST_CACHE_DIR"
    : > "$CACHE_FILE.fail"
    chmod 600 "$CACHE_FILE.fail"
    # Age the marker past the 60s TTL (minimal.json has no rate_limits, so
    # NEED_FALLBACK is true and CACHE_MAX_AGE is 60 here) so the negative
    # cache doesn't block this run's retry.
    age_file "$CACHE_FILE.fail" 120

    run_statusline "$FIXTURES_DIR/minimal.json"
    [ "$status" -eq 0 ]
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ -f "$CACHE_FILE" ]
    [ ! -f "$CACHE_FILE.fail" ]
    clean=$(strip_ansi "$output")
    [[ "$clean" == *"5h:56%"* ]]
    [[ "$clean" == *"w:12%"* ]]
}

@test "model weekly usage: shown in w: after a gray /, general w: still comes from stdin" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    # The general weekly value still comes from stdin's rate_limits.seven_day
    # (37%), not from the usage endpoint's seven_day.utilization (12) or its
    # weekly_all row (44); the model's own weekly usage (80%, from the
    # endpoint's weekly_scoped row for "Fable") follows after a gray "/".
    # full.json's stdin resets_at is 0 ("now") while the API row's resets_at
    # is far-future, so the two windows differ by more than 60s and each
    # gets its own countdown (the two-countdown form).
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)/80%\ \([0-9]+d[0-9]+h\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
    # The w: label takes the worse of the two colors: 37% is green but 80%
    # is yellow, so the label itself renders yellow.
    [[ "$output" == *$'\033[33mw:'* ]]
    [[ "$output" == *$'\033[32m37%'* ]]
    [[ "$output" == *$'\033[33m80%'* ]]
}

@test "model weekly usage: coinciding resets collapse to a single countdown" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    # Build a fixture whose stdin seven_day.resets_at is the exact same
    # instant as the API's Fable weekly_scoped row (computed the same way
    # statusline.sh's own iso_to_epoch does: BSD `date -j -f` first, GNU
    # `date -d` fallback), so WEEK_RESET == MODEL_RESET and the segment
    # collapses to one trailing countdown instead of two.
    local model_reset_iso model_reset_epoch
    model_reset_iso=$(jq -r '.limits[] | select(.kind == "weekly_scoped" and .scope.model.display_name == "Fable") | .resets_at' "$FIXTURES_DIR/usage-limits.json")
    model_reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${model_reset_iso:0:19}" +%s 2>/dev/null || date -d "$model_reset_iso" +%s)

    local fixture="$BATS_TEST_TMPDIR/full-coincide.json"
    jq --argjson wr "$model_reset_epoch" '.rate_limits.seven_day.resets_at = $wr' "$FIXTURES_DIR/full.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%/80%\ \([0-9]+d[0-9]+h\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]

    # Exactly one closing paren inside the w: segment (no second, separate
    # countdown snuck in between "80%" and " | 1h1m").
    local after before paren_close_count
    after=${clean#*w:37%/80% (}
    before=${after%% | 1h1m*}
    paren_close_count=$(printf '%s' "$before" | grep -o ')' | wc -l)
    [ "$paren_close_count" -eq 1 ]
}

@test "model weekly usage: no matching weekly_scoped row -> no / in w:" {
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
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
    [[ "$clean" != *"w:37%/"* ]]
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
    [[ "$clean" =~ ^modelid\ \|\ \$0\.01\ \|\ ctx:1%\ \|\ 5h:5%\ \(now\)\ \|\ w:9%\ \(now\)/42%\ \([0-9]+d[0-9]+h\)\ \|\ 5s\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "model weekly usage: curl returns nothing -> no / in w:, still exits 0" {
    export STUB_SECURITY_TOKEN="stub-token"
    # STUB_CURL_RESPONSE_FILE intentionally left unset: the curl stub is
    # invoked (a token is available) but prints nothing, like a network
    # failure or empty response.

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
    # Proves the fetch path actually ran (and got an empty response), not
    # that it was skipped.
    [ -f "$STUB_CURL_CALLED_MARKER" ]
    [ ! -f "$CACHE_FILE" ]
}

@test "security unavailable: no fetch attempted, no / in w:" {
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
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
}

@test "CLAUDE_STATUSLINE_MODEL_LIMIT=0: no / in w:, curl never called" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"
    export CLAUDE_STATUSLINE_MODEL_LIMIT=0

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    clean=$(strip_ansi "$output")
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
    # Only the all-model value (37%, green) is known, so the label takes its
    # color.
    [[ "$output" == *$'\033[32mw:'* ]]
}

@test "w: label takes the worse (higher) color when the model's own usage is lower than all-model" {
    export STUB_SECURITY_TOKEN="stub-token"
    export STUB_CURL_RESPONSE_FILE="$FIXTURES_DIR/usage-limits.json"

    local fixture="$BATS_TEST_TMPDIR/full-week-95.json"
    jq '.rate_limits.seven_day.used_percentage = 95' "$FIXTURES_DIR/full.json" > "$fixture"

    run_statusline "$fixture"
    [ "$status" -eq 0 ]
    # All-model weekly (95%) is red and worse than the model's own weekly
    # (80%, yellow), so the w: label renders red.
    [[ "$output" == *$'\033[31mw:'* ]]
    [[ "$output" == *$'\033[31m95%'* ]]
    [[ "$output" == *$'\033[33m80%'* ]]
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
    # within the 300s TTL (full.json already carries stdin rate_limits, so
    # only the per-model fetch would need a refresh) and assert it stays
    # absent (values still come from the now-fresh cache, not a second
    # network round trip).
    rm -f "$STUB_CURL_CALLED_MARKER"

    run_statusline "$FIXTURES_DIR/full.json"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_CURL_CALLED_MARKER" ]
    clean=$(strip_ansi "$output")
    [[ "$clean" =~ ^myproj\ \|\ \$1\.23\ \|\ ctx:42%\ \|\ 5h:23%\ \(now\)\ \|\ w:37%\ \(now\)/80%\ \([0-9]+d[0-9]+h\)\ \|\ 1h1m\ \|\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
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
