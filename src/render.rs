//! Turns the collected values into the colored status line. Pure: no I/O and no
//! clock, so every layout decision can be unit-tested.

const CYAN: &str = "\x1b[36m";
const GRAY: &str = "\x1b[90m";
const SAGE: &str = "\x1b[38;5;108m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const RED: &str = "\x1b[31m";
const ORANGE: &str = "\x1b[38;5;208m";
const MAGENTA: &str = "\x1b[35m";
const RESET: &str = "\x1b[0m";

/// Reset countdowns further apart than this get one countdown per value.
const SAME_RESET_WINDOW_SECS: i64 = 60;

#[derive(Debug, Default)]
pub struct Status {
    /// Already sanitized.
    pub dir: String,
    pub cost: f64,
    pub lines_added: u64,
    pub lines_removed: u64,
    pub ctx_pct: u64,
    pub five_hour: Option<f64>,
    pub five_hour_reset: Option<i64>,
    pub week: Option<f64>,
    pub week_reset: Option<i64>,
    pub model_pct: Option<f64>,
    pub model_reset: Option<i64>,
    pub duration_ms: u64,
    /// Already sanitized; the segment is hidden when empty.
    pub model: String,
    pub clock: String,
    pub now: i64,
}

/// A percentage rounded for display; its color follows the rounded value.
struct Percent {
    text: String,
    color: &'static str,
    value: f64,
}

impl Percent {
    fn new(value: f64) -> Self {
        let text = format!("{value:.0}");
        let value: f64 = text.parse().unwrap_or(value);
        Self {
            text,
            color: color_for(value),
            value,
        }
    }

    fn colored(&self) -> String {
        format!("{}{}%{RESET}", self.color, self.text)
    }
}

fn color_for(pct: f64) -> &'static str {
    if pct >= 90.0 {
        RED
    } else if pct >= 70.0 {
        YELLOW
    } else {
        GREEN
    }
}

/// `XdYh`, `XhYm`, `XmYs` or `Xs`; `now` for anything not in the future.
pub fn format_duration(secs: i64) -> String {
    if secs <= 0 {
        return "now".to_string();
    }
    let (days, hours) = (secs / 86400, secs % 86400 / 3600);
    let (mins, rest) = (secs % 3600 / 60, secs % 60);
    if days > 0 {
        format!("{days}d{hours}h")
    } else if hours > 0 {
        format!("{hours}h{mins}m")
    } else if mins > 0 {
        format!("{mins}m{rest}s")
    } else {
        format!("{rest}s")
    }
}

fn countdown(reset: i64, now: i64) -> String {
    format!("{GRAY}({}){RESET}", format_duration(reset - now))
}

fn five_hour_segment(status: &Status) -> Option<String> {
    let pct = Percent::new(status.five_hour?);
    let mut segment = format!("{}5h:{}%{RESET}", pct.color, pct.text);
    if let Some(reset) = status.five_hour_reset {
        segment.push(' ');
        segment.push_str(&countdown(reset, status.now));
    }
    Some(segment)
}

/// All-model weekly usage, then a gray `/` and the model's own. One countdown
/// when the windows reset together, otherwise one per value.
fn week_segment(status: &Status) -> Option<String> {
    let week = status.week.map(Percent::new);
    let model = status.model_pct.map(Percent::new);

    let worst = match (&week, &model) {
        (Some(w), Some(m)) => w.value.max(m.value),
        (Some(p), None) | (None, Some(p)) => p.value,
        (None, None) => return None,
    };
    let label = format!("{}w:{RESET}", color_for(worst));
    let week_text = week
        .as_ref()
        .map_or_else(|| format!("{GRAY}-{RESET}"), Percent::colored);
    let model_text = model
        .as_ref()
        .map_or_else(String::new, |m| format!("{GRAY}/{RESET}{}", m.colored()));

    if let (Some(_), Some(_), Some(week_reset), Some(model_reset)) =
        (&week, &model, status.week_reset, status.model_reset)
        && (week_reset - model_reset).abs() > SAME_RESET_WINDOW_SECS
    {
        let now = status.now;
        return Some(format!(
            "{label}{week_text} {}{model_text} {}",
            countdown(week_reset, now),
            countdown(model_reset, now)
        ));
    }

    let mut segment = format!("{label}{week_text}{model_text}");
    if let Some(reset) = status.week_reset.or(status.model_reset) {
        segment.push(' ');
        segment.push_str(&countdown(reset, status.now));
    }
    Some(segment)
}

/// `dir | $cost | +add/-del | ctx:N% | 5h:N% (reset) | w:ALL%/MODEL% (reset) |
/// duration | model | clock`, skipping segments with nothing to show.
pub fn render(status: &Status) -> String {
    let mut segments = vec![
        format!("{CYAN}{}{RESET}", status.dir),
        format!("{YELLOW}${:.2}{RESET}", status.cost),
    ];
    if status.lines_added > 0 || status.lines_removed > 0 {
        segments.push(format!(
            "{GREEN}+{}{RESET}{GRAY}/{RESET}{RED}-{}{RESET}",
            status.lines_added, status.lines_removed
        ));
    }
    let ctx_color = color_for(status.ctx_pct as f64);
    segments.push(format!("{ctx_color}ctx:{}%{RESET}", status.ctx_pct));
    segments.extend(five_hour_segment(status));
    segments.extend(week_segment(status));

    let secs = i64::try_from(status.duration_ms / 1000).unwrap_or(i64::MAX);
    segments.push(format!("{SAGE}{}{RESET}", format_duration(secs)));
    if !status.model.is_empty() {
        segments.push(format!("{MAGENTA}{}{RESET}", status.model));
    }
    segments.push(format!("{ORANGE}{}{RESET}", status.clock));
    segments.join(" | ")
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_000_000;

    fn status() -> Status {
        Status {
            dir: "proj".into(),
            cost: 1.234,
            ctx_pct: 42,
            duration_ms: 3_661_000,
            clock: "12:30:13".into(),
            now: NOW,
            ..Status::default()
        }
    }

    fn plain(line: &str) -> String {
        let mut out = String::new();
        let mut rest = line;
        while let Some(start) = rest.find('\x1b') {
            out.push_str(&rest[..start]);
            let end = rest[start..]
                .find('m')
                .map_or(rest.len(), |i| start + i + 1);
            rest = &rest[end..];
        }
        out + rest
    }

    #[test]
    fn format_duration_buckets() {
        for (secs, expected) in [
            (-5, "now"),
            (0, "now"),
            (1, "1s"),
            (59, "59s"),
            (60, "1m0s"),
            (3599, "59m59s"),
            (3600, "1h0m"),
            (3750, "1h2m"),
            (86399, "23h59m"),
            (86400, "1d0h"),
            (91800, "1d1h"),
        ] {
            assert_eq!(format_duration(secs), expected, "{secs}");
        }
    }

    #[test]
    fn color_thresholds() {
        for (pct, color) in [(69.0, GREEN), (70.0, YELLOW), (89.0, YELLOW), (90.0, RED)] {
            assert_eq!(color_for(pct), color, "{pct}");
        }
    }

    #[test]
    fn percent_rounds_like_printf_and_colors_the_rounded_value() {
        let pct = Percent::new(69.6);
        assert_eq!(pct.text, "70");
        assert_eq!(pct.color, YELLOW);
        assert_eq!(Percent::new(2.5).text, "2");
        assert_eq!(Percent::new(3.5).text, "4");
    }

    #[test]
    fn minimal_line_has_no_optional_segments() {
        assert_eq!(
            plain(&render(&status())),
            "proj | $1.23 | ctx:42% | 1h1m | 12:30:13"
        );
    }

    #[test]
    fn full_line_order_is_stable_with_clock_last() {
        let line = render(&Status {
            lines_added: 12,
            lines_removed: 3,
            five_hour: Some(23.4),
            five_hour_reset: Some(NOW + 3750),
            week: Some(37.2),
            week_reset: Some(NOW + 91800),
            model_pct: Some(80.0),
            model_reset: Some(NOW + 91800),
            model: "Fable 5.1".into(),
            ..status()
        });
        assert_eq!(
            plain(&line),
            "proj | $1.23 | +12/-3 | ctx:42% | 5h:23% (1h2m) | w:37%/80% (1d1h) | 1h1m | Fable 5.1 | 12:30:13"
        );
    }

    #[test]
    fn distant_resets_get_one_countdown_each() {
        let line = render(&Status {
            week: Some(37.0),
            week_reset: Some(NOW - 1),
            model_pct: Some(80.0),
            model_reset: Some(NOW + 3750),
            ..status()
        });
        assert!(plain(&line).contains("w:37% (now)/80% (1h2m) |"), "{line}");
    }

    #[test]
    fn resets_within_a_minute_collapse_week_reset_wins() {
        let line = render(&Status {
            week: Some(37.0),
            week_reset: Some(NOW + 3750),
            model_pct: Some(80.0),
            model_reset: Some(NOW + 3750 + 60),
            ..status()
        });
        assert!(plain(&line).contains("w:37%/80% (1h2m) |"), "{line}");
    }

    #[test]
    fn only_model_value_known_shows_gray_dash() {
        let line = render(&Status {
            model_pct: Some(80.0),
            model_reset: Some(NOW + 3750),
            ..status()
        });
        assert!(plain(&line).contains("w:-/80% (1h2m) |"), "{line}");
        assert!(line.contains(&format!("{GRAY}-{RESET}")));
    }

    #[test]
    fn week_segment_hidden_when_nothing_known_even_with_a_reset() {
        let line = render(&Status {
            week_reset: Some(NOW + 60),
            ..status()
        });
        assert!(!plain(&line).contains("w:"), "{line}");
    }

    #[test]
    fn week_label_takes_the_worse_color() {
        let line = render(&Status {
            week: Some(95.0),
            model_pct: Some(80.0),
            ..status()
        });
        assert!(line.contains(&format!("{RED}w:")), "{line}");
        assert!(line.contains(&format!("{RED}95%")), "{line}");
        assert!(line.contains(&format!("{YELLOW}80%")), "{line}");
    }

    #[test]
    fn five_hour_without_reset_has_no_countdown() {
        let line = render(&Status {
            five_hour: Some(23.0),
            ..status()
        });
        assert!(plain(&line).contains("5h:23% | "), "{line}");
    }
}
