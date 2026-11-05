//! Claude Code status line with real-time Max/Pro rate-limit data.
//!
//! Reads Claude Code's JSON from stdin and prints one colored line. See
//! [`render::render`] for the layout and `README.md` for how rate limits are
//! obtained. It always exits 0: a status line has nowhere to report errors, so
//! whatever can't be determined is simply left out.

mod input;
mod render;
mod usage;

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use chrono::Local;

use input::{Input, dir_display, sanitize};
use render::{Status, render};
use usage::{UsageCache, fallback_values, model_limit};

/// Cache age when the 5h/w fallback itself needs the data (time-sensitive).
const FALLBACK_MAX_AGE_SECS: i64 = 60;
/// Cache age when only the per-model value does (less urgent).
const MODEL_ONLY_MAX_AGE_SECS: i64 = 300;

fn main() {
    let mut stdin = Vec::new();
    let _ = io::stdin().read_to_end(&mut stdin);
    // Claude Code shows no status line when there's no output.
    if stdin.iter().all(|byte| is_space(*byte)) {
        return;
    }

    let input = Input::parse(&String::from_utf8_lossy(&stdin));
    let line = render(&collect(&input));
    let _ = writeln!(io::stdout(), "{line}");
}

fn is_space(byte: u8) -> bool {
    byte.is_ascii_whitespace() || byte == 0x0b
}

fn collect(input: &Input) -> Status {
    let home = env::var("HOME").unwrap_or_default();
    let now = Local::now();
    let mut status = Status {
        dir: dir_display(&input.dir, &home),
        cost: input.cost,
        lines_added: input.lines_added,
        lines_removed: input.lines_removed,
        ctx_pct: input.ctx_pct,
        five_hour: input.five_hour,
        five_hour_reset: input.five_hour_reset,
        week: input.week,
        week_reset: input.week_reset,
        duration_ms: input.duration_ms,
        model: sanitize(input.model_name()),
        clock: now.format("%H:%M:%S").to_string(),
        now: now.timestamp(),
        ..Status::default()
    };

    let need_fallback = input.five_hour.is_none() && input.week.is_none();
    let need_model_limit =
        model_limit_enabled() && !input.model_name().is_empty() && has_security();
    if !need_fallback && !need_model_limit {
        return status;
    }

    let max_age = if need_fallback {
        FALLBACK_MAX_AGE_SECS
    } else {
        MODEL_ONLY_MAX_AGE_SECS
    };
    let cache = UsageCache::new(&cache_dir(&home), max_age);
    cache.refresh();
    let Some(response) = cache.read() else {
        return status;
    };

    if need_fallback {
        let fallback = fallback_values(&response);
        status.five_hour = fallback.five_hour;
        status.week = fallback.week;
        if let Some(reset) = fallback.five_hour_reset {
            status.five_hour_reset = reset;
        }
        if let Some(reset) = fallback.week_reset {
            status.week_reset = reset;
        }
    }
    if need_model_limit
        && let Some((pct, reset)) = model_limit(&response, &input.model_display, &input.model_id)
    {
        status.model_pct = Some(pct);
        status.model_reset = reset;
    }
    status
}

fn model_limit_enabled() -> bool {
    env::var("CLAUDE_STATUSLINE_MODEL_LIMIT").as_deref() != Ok("0")
}

fn cache_dir(home: &str) -> PathBuf {
    match env::var_os("CLAUDE_STATUSLINE_CACHE_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => PathBuf::from(home).join(".claude/cache"),
    }
}

/// Whether the macOS `security` tool is on `PATH`; never true on Linux.
fn has_security() -> bool {
    env::var_os("PATH").is_some_and(|path| {
        env::split_paths(&path).any(|dir| {
            dir.join("security")
                .metadata()
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })
    })
}
