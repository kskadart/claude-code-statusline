#!/bin/bash
# Claude Code statusline with real-time Max/Pro rate-limit data.
#
# Layout:
#   dir | $cost | +add/-del | ctx:N% | 5h:N% (reset) | 7d:N% (reset) | session_duration | time
#
# Rate-limit strategy:
#   1. Prefer Claude Code's built-in rate_limits field (future-proof if the bug is fixed)
#   2. Fall back to direct query of https://api.anthropic.com/api/oauth/usage using the
#      OAuth token from macOS Keychain (Claude Code-credentials), cached to
#      $HOME/.claude/cache/statusline-ratelimit.json for 60s to avoid spamming the endpoint.
#      Override the cache directory with CLAUDE_STATUSLINE_CACHE_DIR.

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

# Fallback: query Anthropic OAuth usage endpoint directly when Claude Code doesn't surface it
if [ -z "$FIVE_H" ] && [ -z "$WEEK" ]; then
    CACHE_DIR="${CLAUDE_STATUSLINE_CACHE_DIR:-$HOME/.claude/cache}"
    CACHE="$CACHE_DIR/statusline-ratelimit.json"
    mkdir -p "$CACHE_DIR"
    CACHE_MAX_AGE=60

    cache_stale=true
    if [ -f "$CACHE" ]; then
        cache_mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [ $((now_epoch - cache_mtime)) -le $CACHE_MAX_AGE ]; then
            cache_stale=false
        fi
    fi

    if [ "$cache_stale" = true ]; then
        TOKEN=$(security find-generic-password -a "$USER" -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        if [ -n "$TOKEN" ]; then
            curl -s --max-time 2 \
                -H "Authorization: Bearer $TOKEN" \
                -H "anthropic-beta: oauth-2025-04-20" \
                https://api.anthropic.com/api/oauth/usage > "$CACHE.tmp" 2>/dev/null
            if [ -s "$CACHE.tmp" ] && jq -e '.five_hour.utilization' "$CACHE.tmp" >/dev/null 2>&1; then
                chmod 600 "$CACHE.tmp"
                mv "$CACHE.tmp" "$CACHE"
            else
                rm -f "$CACHE.tmp"
            fi
        fi
    fi

    if [ -f "$CACHE" ]; then
        FIVE_H=$(jq -r '.five_hour.utilization // empty' "$CACHE" 2>/dev/null)
        FIVE_H_ISO=$(jq -r '.five_hour.resets_at // empty' "$CACHE" 2>/dev/null)
        WEEK=$(jq -r '.seven_day.utilization // empty' "$CACHE" 2>/dev/null)
        WEEK_ISO=$(jq -r '.seven_day.resets_at // empty' "$CACHE" 2>/dev/null)

        # ISO8601 UTC "YYYY-MM-DDTHH:MM:SS..." → Unix epoch (macOS date uses -j -f)
        if [ -n "$FIVE_H_ISO" ]; then
            FIVE_H_RESET=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${FIVE_H_ISO:0:19}" +%s 2>/dev/null || \
                           date -d "${FIVE_H_ISO}" +%s 2>/dev/null)
        fi
        if [ -n "$WEEK_ISO" ]; then
            WEEK_RESET=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${WEEK_ISO:0:19}" +%s 2>/dev/null || \
                         date -d "${WEEK_ISO}" +%s 2>/dev/null)
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

if [ -n "$WEEK" ]; then
    WEEK_INT=$(printf '%.0f' "$WEEK")
    WEEK_COLOR=$(color_for_pct "$WEEK_INT")
    SEG="${WEEK_COLOR}7d:${WEEK_INT}%${RESET}"
    if [ -n "$WEEK_RESET" ]; then
        DIFF=$((WEEK_RESET - NOW))
        SEG="${SEG} ${GRAY}($(format_duration "$DIFF"))${RESET}"
    fi
    LINE="${LINE} | ${SEG}"
fi

LINE="${LINE} | ${SAGE}${DUR_FMT}${RESET}"
LINE="${LINE} | ${ORANGE}${TIME}${RESET}"

printf '%b\n' "$LINE"
