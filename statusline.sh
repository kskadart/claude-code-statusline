#!/bin/bash
# Claude Code statusline with real-time Max/Pro rate-limit data.
#
# Layout:
#   dir | $cost | +add/-del | ctx:N% | 5h:N% (reset) | w:ALL%/MODEL% (reset) | session_duration | time
#
# The model isn't its own segment: its identity is conveyed only by the
# second value of the w: segment (the current model's own weekly usage,
# after a gray "/").
#
# Rate-limit strategy:
#   1. Prefer Claude Code's built-in rate_limits field (future-proof if the bug is fixed)
#      for the 5h/w segments.
#   2. Fall back to direct query of https://api.anthropic.com/api/oauth/usage using the
#      OAuth token from macOS Keychain (Claude Code-credentials), cached to
#      $HOME/.claude/cache/statusline-ratelimit.json for 60s (when the fallback itself is
#      needed) to avoid spamming the endpoint. Override the cache directory with
#      CLAUDE_STATUSLINE_CACHE_DIR.
#   3. The model's own weekly usage (shown in the w: segment after a gray "/") is not in
#      stdin; it is read from the same usage endpoint/cache, fetched at most once per
#      render whenever a model name is known. When that per-model fetch is the only reason
#      to talk to the endpoint (stdin already had rate_limits), the cache TTL is 300s
#      instead of 60s, so it's refreshed at most every 5 minutes. Disable with
#      CLAUDE_STATUSLINE_MODEL_LIMIT=0.
#   4. A failed fetch (no token, curl error, invalid JSON) leaves a marker
#      ($CACHE.fail, mode 600) so the next attempt is skipped until the same TTL elapses;
#      a successful fetch clears it. An existing (older) cache is still used for rendering
#      even while a refresh is skipped or fails.

# Number parsing/formatting must not depend on the user's locale (printf %.2f with de_DE/ru_RU breaks)
export LC_ALL=C

input=$(cat)

DIR=$(printf '%s' "$input" | jq -r '.workspace.current_dir')

# zsh %1~: last path component, with $HOME abbreviated as ~
if [ "$DIR" = "$HOME" ]; then
    DIR_DISPLAY="~"
else
    DIR_DISPLAY="${DIR##*/}"
fi

# Model name/id: one jq call extracts both raw fields (empty string when
# absent/null/not-a-string), silently on malformed input. Display name wins,
# falling back to id; MODEL_NAME is empty when neither is a non-empty
# string. The model name itself is never rendered; MODEL_NAME gates whether
# the per-model weekly-usage fetch runs at all, and MODEL_DISPLAY/MODEL_ID
# (raw) are used later to match the model's own weekly-limit row from the
# usage endpoint.
MODEL_TSV=$(printf '%s' "$input" | jq -r '
    def pick(f): ([f] | map(select(type == "string" and . != ""))) as $vals
        | if ($vals | length) > 0 then $vals[0] else "" end;
    [pick(.model.display_name?), pick(.model.id?)] | @tsv
' 2>/dev/null)
MODEL_DISPLAY=${MODEL_TSV%%$'\t'*}
MODEL_ID=${MODEL_TSV#*$'\t'}
# No tab at all in MODEL_TSV (e.g. jq itself failed): the # expansion above
# returns the whole string unchanged, so reset MODEL_ID to empty.
if [ "$MODEL_ID" = "$MODEL_TSV" ]; then
    MODEL_ID=""
fi

if [ -n "$MODEL_DISPLAY" ]; then
    MODEL_NAME="$MODEL_DISPLAY"
else
    MODEL_NAME="$MODEL_ID"
fi

COST=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // 0')
DUR_MS=$(printf '%s' "$input" | jq -r '.cost.total_duration_ms // 0')
LINES_ADD=$(printf '%s' "$input" | jq -r '.cost.total_lines_added // 0')
LINES_DEL=$(printf '%s' "$input" | jq -r '.cost.total_lines_removed // 0')
PCT=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Try built-in rate_limits field first
FIVE_H=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_H_RESET=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
WEEK=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
WEEK_RESET=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

CACHE_DIR="${CLAUDE_STATUSLINE_CACHE_DIR:-$HOME/.claude/cache}"
CACHE="$CACHE_DIR/statusline-ratelimit.json"

# Fallback needed when Claude Code doesn't surface rate_limits on stdin.
NEED_FALLBACK=false
if [ -z "$FIVE_H" ] && [ -z "$WEEK" ]; then
    NEED_FALLBACK=true
fi

# Cache TTL: 60s when the 5h/w fallback itself is needed (time-sensitive),
# 300s when the only reason to fetch is the per-model weekly usage (less
# urgent, and keeps the endpoint call infrequent).
if [ "$NEED_FALLBACK" = true ]; then
    CACHE_MAX_AGE=60
else
    CACHE_MAX_AGE=300
fi

# Per-model weekly usage: opt-out via CLAUDE_STATUSLINE_MODEL_LIMIT=0, and
# only worth fetching when a model name is actually known.
MODEL_LIMIT_ENABLED=true
if [ "${CLAUDE_STATUSLINE_MODEL_LIMIT:-}" = "0" ]; then
    MODEL_LIMIT_ENABLED=false
fi

NEED_MODEL_LIMIT=false
if [ "$MODEL_LIMIT_ENABLED" = true ] && [ -n "$MODEL_NAME" ] && command -v security >/dev/null 2>&1; then
    NEED_MODEL_LIMIT=true
fi

# ISO8601 UTC "YYYY-MM-DDTHH:MM:SS..." -> Unix epoch (macOS date uses -j -f)
iso_to_epoch() {
    local iso="$1"
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${iso:0:19}" +%s 2>/dev/null || \
        date -d "${iso}" +%s 2>/dev/null
}

# True if $1 (a file path) exists and is no older than CACHE_MAX_AGE.
file_fresh() {
    local file="$1"
    [ -f "$file" ] || return 1
    local mtime now_epoch
    mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    [ $((now_epoch - mtime)) -le $CACHE_MAX_AGE ]
}

# Refresh $CACHE from the Anthropic OAuth usage endpoint if it's missing or
# older than CACHE_MAX_AGE. Called at most once per render. A failed fetch
# (no token, curl error, invalid JSON) leaves a $CACHE.fail marker so the
# next call skips retrying until it too is older than CACHE_MAX_AGE; a
# successful fetch clears that marker. An existing stale cache is left in
# place either way and is still used by the caller for rendering.
refresh_usage_cache() {
    if file_fresh "$CACHE"; then
        return
    fi
    if file_fresh "$CACHE.fail"; then
        return
    fi

    mkdir -p "$CACHE_DIR"
    local token
    token=$(security find-generic-password -a "$USER" -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -n "$token" ]; then
        ( umask 077; curl -s --max-time 2 \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            https://api.anthropic.com/api/oauth/usage > "$CACHE.tmp" 2>/dev/null )
        if [ -s "$CACHE.tmp" ] && jq -e '.five_hour.utilization' "$CACHE.tmp" >/dev/null 2>&1; then
            chmod 600 "$CACHE.tmp"
            mv "$CACHE.tmp" "$CACHE"
            rm -f "$CACHE.fail"
            return
        else
            rm -f "$CACHE.tmp"
        fi
    fi

    ( umask 077; : > "$CACHE.fail" )
    chmod 600 "$CACHE.fail" 2>/dev/null
}

if [ "$NEED_FALLBACK" = true ] || [ "$NEED_MODEL_LIMIT" = true ]; then
    refresh_usage_cache
fi

if [ "$NEED_FALLBACK" = true ] && [ -f "$CACHE" ]; then
    FIVE_H=$(jq -r '.five_hour.utilization // empty' "$CACHE" 2>/dev/null)
    FIVE_H_ISO=$(jq -r '.five_hour.resets_at // empty' "$CACHE" 2>/dev/null)
    WEEK=$(jq -r '.seven_day.utilization // empty' "$CACHE" 2>/dev/null)
    WEEK_ISO=$(jq -r '.seven_day.resets_at // empty' "$CACHE" 2>/dev/null)

    if [ -n "$FIVE_H_ISO" ]; then
        FIVE_H_RESET=$(iso_to_epoch "$FIVE_H_ISO")
    fi
    if [ -n "$WEEK_ISO" ]; then
        WEEK_RESET=$(iso_to_epoch "$WEEK_ISO")
    fi
fi

# Model's own weekly usage: the weekly_scoped row in the cached usage
# response whose scope.model.display_name matches the current model
# (case-insensitively, by id-contains or display-name-startswith). Hidden
# (name only) when disabled, no model, fetch failed, or no matching row.
MODEL_PCT=""
MODEL_RESET=""
if [ "$NEED_MODEL_LIMIT" = true ] && [ -f "$CACHE" ]; then
    MODEL_LIMIT_TSV=$(jq -r --arg id "$MODEL_ID" --arg disp "$MODEL_DISPLAY" '
        def matches(row):
            (row.scope.model.display_name // "" | ascii_downcase) as $n
            | $n != "" and (
                if ($disp != "") then ($disp | ascii_downcase | startswith($n))
                else ($id | ascii_downcase | contains($n)) end
              );
        ((.limits // []) | map(select(.kind == "weekly_scoped" and matches(.) and ((.percent | type) == "number"))))[0] as $row
        | if $row == null then empty
          else [($row.percent | if . < 0 then 0 elif . > 999 then 999 else . end | tostring), ($row.resets_at // "")] | @tsv
          end
    ' "$CACHE" 2>/dev/null)

    if [ -n "$MODEL_LIMIT_TSV" ]; then
        IFS=$'\t' read -r MODEL_PCT MODEL_RESET_ISO <<<"$MODEL_LIMIT_TSV"
        if [ -n "$MODEL_RESET_ISO" ]; then
            MODEL_RESET=$(iso_to_epoch "$MODEL_RESET_ISO")
        fi
    fi
fi

TIME=$(date +%H:%M:%S)
NOW=$(date +%s)

CYAN='\033[36m'
GRAY='\033[90m'
SAGE='\033[38;5;108m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
ORANGE='\033[38;5;208m'
RESET='\033[0m'

# Pick a color based on a 0-100 usage percentage
color_for_pct() {
    local p="$1"
    if [ "$p" -ge 90 ]; then
        printf '%s' "$RED"
    elif [ "$p" -ge 70 ]; then
        printf '%s' "$YELLOW"
    else
        printf '%s' "$GREEN"
    fi
}

# Format a positive duration in seconds as "XdYh", "XhYm", "XmYs", or "Xs"
format_duration() {
    local secs="$1"
    if [ "$secs" -le 0 ]; then
        printf 'now'
        return
    fi
    local days=$((secs / 86400))
    local hours=$(((secs % 86400) / 3600))
    local mins=$(((secs % 3600) / 60))
    local remaining=$((secs % 60))
    if [ "$days" -gt 0 ]; then
        printf '%dd%dh' "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then
        printf '%dh%dm' "$hours" "$mins"
    elif [ "$mins" -gt 0 ]; then
        printf '%dm%ds' "$mins" "$remaining"
    else
        printf '%ds' "$remaining"
    fi
}

CTX_COLOR=$(color_for_pct "$PCT")
COST_FMT=$(printf '$%.2f' "$COST")
DUR_SEC=$((DUR_MS / 1000))
DUR_FMT=$(format_duration "$DUR_SEC")

LINE="${CYAN}${DIR_DISPLAY}${RESET}"

LINE="${LINE} | ${YELLOW}${COST_FMT}${RESET}"

if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_DEL" -gt 0 ]; then
    LINE="${LINE} | ${GREEN}+${LINES_ADD}${RESET}${GRAY}/${RESET}${RED}-${LINES_DEL}${RESET}"
fi

LINE="${LINE} | ${CTX_COLOR}ctx:${PCT}%${RESET}"

if [ -n "$FIVE_H" ]; then
    FIVE_H_INT=$(printf '%.0f' "$FIVE_H")
    FIVE_H_COLOR=$(color_for_pct "$FIVE_H_INT")
    SEG="${FIVE_H_COLOR}5h:${FIVE_H_INT}%${RESET}"
    if [ -n "$FIVE_H_RESET" ]; then
        DIFF=$((FIVE_H_RESET - NOW))
        SEG="${SEG} ${GRAY}($(format_duration "$DIFF"))${RESET}"
    fi
    LINE="${LINE} | ${SEG}"
fi

# Weekly segment: WEEK (all models, from stdin/fallback) plus, when known,
# the current model's own weekly usage after a gray "/". Hidden entirely
# when neither is known. One reset countdown for the whole segment when
# only one of WEEK_RESET/MODEL_RESET is known, or both are known and differ
# by at most 60s (WEEK_RESET wins when both qualify); otherwise each value
# gets its own countdown right after it.
if [ -n "$WEEK" ] || [ -n "$MODEL_PCT" ]; then
    if [ -n "$WEEK" ]; then
        WEEK_INT=$(printf '%.0f' "$WEEK")
        WEEK_COLOR=$(color_for_pct "$WEEK_INT")
        WEEK_VAL="${WEEK_COLOR}${WEEK_INT}%${RESET}"
    else
        WEEK_VAL="${GRAY}-${RESET}"
    fi

    MODEL_VAL=""
    if [ -n "$MODEL_PCT" ]; then
        MODEL_PCT_INT=$(printf '%.0f' "$MODEL_PCT")
        MODEL_PCT_COLOR=$(color_for_pct "$MODEL_PCT_INT")
        MODEL_VAL="${GRAY}/${RESET}${MODEL_PCT_COLOR}${MODEL_PCT_INT}%${RESET}"
    fi

    SPLIT_RESETS=false
    if [ -n "$WEEK" ] && [ -n "$MODEL_PCT" ] && [ -n "$WEEK_RESET" ] && [ -n "$MODEL_RESET" ]; then
        RESET_DIFF=$((WEEK_RESET - MODEL_RESET))
        if [ "$RESET_DIFF" -lt 0 ]; then
            RESET_DIFF=$((-RESET_DIFF))
        fi
        if [ "$RESET_DIFF" -gt 60 ]; then
            SPLIT_RESETS=true
        fi
    fi

    if [ "$SPLIT_RESETS" = true ]; then
        WEEK_VAL="${WEEK_VAL} ${GRAY}($(format_duration $((WEEK_RESET - NOW))))${RESET}"
        MODEL_VAL="${MODEL_VAL} ${GRAY}($(format_duration $((MODEL_RESET - NOW))))${RESET}"
        SEG="w:${WEEK_VAL}${MODEL_VAL}"
    else
        SEG="w:${WEEK_VAL}${MODEL_VAL}"
        RESET_AT=""
        if [ -n "$WEEK_RESET" ]; then
            RESET_AT="$WEEK_RESET"
        elif [ -n "$MODEL_RESET" ]; then
            RESET_AT="$MODEL_RESET"
        fi
        if [ -n "$RESET_AT" ]; then
            SEG="${SEG} ${GRAY}($(format_duration $((RESET_AT - NOW))))${RESET}"
        fi
    fi

    LINE="${LINE} | ${SEG}"
fi

LINE="${LINE} | ${SAGE}${DUR_FMT}${RESET}"
LINE="${LINE} | ${ORANGE}${TIME}${RESET}"

printf '%b\n' "$LINE"
