//! Typed view of the JSON Claude Code pipes to stdin.
//!
//! Everything here is untrusted: a field can have any JSON type, or be absent.
//! Each accessor reduces it to a plain number or a string that still has to go
//! through [`sanitize`] before it's printed.

use serde_json::Value;

/// Parsed stdin. Invalid JSON yields the default: no fields known.
#[derive(Debug, Default, PartialEq)]
pub struct Input {
    pub dir: String,
    pub model_display: String,
    pub model_id: String,
    pub cost: f64,
    pub duration_ms: u64,
    pub lines_added: u64,
    pub lines_removed: u64,
    pub ctx_pct: u64,
    pub five_hour: Option<f64>,
    pub five_hour_reset: Option<i64>,
    pub week: Option<f64>,
    pub week_reset: Option<i64>,
}

impl Input {
    pub fn parse(text: &str) -> Self {
        match serde_json::from_str::<Value>(text) {
            Ok(root) => Self::from_value(&root),
            Err(_) => Self::default(),
        }
    }

    fn from_value(root: &Value) -> Self {
        let int = |path: &[&str]| truthy(root, path).and_then(|s| integer(&s)).unwrap_or(0);

        Self {
            dir: non_empty_str(root, &["workspace", "current_dir"]),
            model_display: non_empty_str(root, &["model", "display_name"]),
            model_id: non_empty_str(root, &["model", "id"]),
            cost: truthy(root, &["cost", "total_cost_usd"]).map_or(0.0, |s| number(&s)),
            duration_ms: int(&["cost", "total_duration_ms"]),
            lines_added: int(&["cost", "total_lines_added"]),
            lines_removed: int(&["cost", "total_lines_removed"]),
            ctx_pct: int(&["context_window", "used_percentage"]),
            five_hour: percent(root, &["rate_limits", "five_hour", "used_percentage"]),
            five_hour_reset: epoch(root, &["rate_limits", "five_hour", "resets_at"]),
            week: percent(root, &["rate_limits", "seven_day", "used_percentage"]),
            week_reset: epoch(root, &["rate_limits", "seven_day", "resets_at"]),
        }
    }

    /// Display name, falling back to the id. Empty when neither is known.
    pub fn model_name(&self) -> &str {
        if self.model_display.is_empty() {
            &self.model_id
        } else {
            &self.model_display
        }
    }
}

/// Walks object keys; anything that isn't an object along the way is "absent".
pub fn lookup<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter()
        .try_fold(root, |value, key| value.as_object()?.get(*key))
}

/// The value as text, unless it's absent, null, false or an empty string.
pub fn truthy(root: &Value, path: &[&str]) -> Option<String> {
    lookup(root, path)
        .filter(|value| !matches!(value, Value::Null | Value::Bool(false)))
        .map(raw)
        .filter(|text| !text.is_empty())
}

/// A percentage from a present field; a non-numeric value counts as 0.
pub fn percent(root: &Value, path: &[&str]) -> Option<f64> {
    truthy(root, path).map(|text| number(&text))
}

fn epoch(root: &Value, path: &[&str]) -> Option<i64> {
    truthy(root, path)
        .and_then(|text| integer(&text))
        .and_then(|value| i64::try_from(value).ok())
}

fn non_empty_str(root: &Value, path: &[&str]) -> String {
    lookup(root, path)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn raw(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// The integer part of a digit string (`"42.7"` gives 42). Anything else,
/// including a negative number or a hostile string, is `None`.
pub fn integer(text: &str) -> Option<u64> {
    let int = text.split('.').next().unwrap_or_default();
    if int.is_empty() || !int.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    int.parse().ok()
}

/// A finite number, or 0 for anything else.
pub fn number(text: &str) -> f64 {
    text.trim()
        .parse()
        .ok()
        .filter(|value: &f64| value.is_finite())
        .unwrap_or(0.0)
}

/// Removes control characters so a value can't break the single-line layout or
/// inject terminal escapes. Other characters, such as emoji, stay untouched.
pub fn sanitize(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).collect()
}

/// The last path component, or `~` for the home directory. Empty when the
/// directory is unknown, even if `HOME` is unset too.
pub fn dir_display(dir: &str, home: &str) -> String {
    let name = if dir.is_empty() {
        ""
    } else if dir == home {
        "~"
    } else {
        dir.rsplit('/').next().unwrap_or_default()
    };
    sanitize(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn integer_takes_the_integer_part_and_rejects_the_rest() {
        assert_eq!(integer("42"), Some(42));
        assert_eq!(integer("42.7"), Some(42));
        for bad in [
            "",
            ".5",
            "-5",
            "true",
            "1e+21",
            "a[$(touch x)]",
            "\u{1b}[31m",
        ] {
            assert_eq!(integer(bad), None, "{bad:?}");
        }
        assert_eq!(integer("99999999999999999999999"), None);
    }

    #[test]
    fn number_rejects_non_finite_and_garbage() {
        assert_eq!(number("1.5"), 1.5);
        assert_eq!(number("-3"), -3.0);
        for bad in ["", "abc", "inf", "NaN", "\u{1b}[31m"] {
            assert_eq!(number(bad), 0.0, "{bad:?}");
        }
    }

    #[test]
    fn sanitize_strips_control_characters_only() {
        assert_eq!(sanitize("a\nb\u{1b}c\u{7f}"), "abc");
        assert_eq!(sanitize("a\u{9b}31mb"), "a31mb");
        assert_eq!(sanitize("проект 🚀"), "проект 🚀");
    }

    #[test]
    fn dir_display_cases() {
        assert_eq!(dir_display("/home/u", "/home/u"), "~");
        assert_eq!(dir_display("/home/u/proj", "/home/u"), "proj");
        assert_eq!(dir_display("/tmp/a\nb\u{1b}c", "/home/u"), "abc");
        assert_eq!(dir_display(r"/tmp/foo\nbar", "/home/u"), r"foo\nbar");
        assert_eq!(dir_display("", "/home/u"), "");
        assert_eq!(dir_display("", ""), "");
    }

    #[test]
    fn only_a_string_counts_as_the_current_dir() {
        for workspace in [
            json!(null),
            json!("x"),
            json!({}),
            json!({"current_dir": null}),
            json!({"current_dir": 5}),
            json!({"current_dir": ["/tmp"]}),
        ] {
            let input = Input::from_value(&json!({"workspace": workspace}));
            assert_eq!(input.dir, "", "{workspace}");
        }
        let input = Input::from_value(&json!({"workspace": {"current_dir": "/tmp/a"}}));
        assert_eq!(input.dir, "/tmp/a");
    }

    #[test]
    fn model_name_prefers_display_name_and_ignores_non_strings() {
        let both = Input::from_value(&json!({"model": {"display_name": "Opus 5", "id": "x"}}));
        assert_eq!(both.model_name(), "Opus 5");
        let empty = Input::from_value(&json!({"model": {"display_name": "", "id": "x"}}));
        assert_eq!(empty.model_name(), "x");
        let wrong = Input::from_value(&json!({"model": {"display_name": 5, "id": ["x"]}}));
        assert_eq!(wrong.model_name(), "");
        assert_eq!(Input::from_value(&json!({"model": null})).model_name(), "");
    }

    #[test]
    fn hostile_numeric_fields_are_neutralized() {
        let input = Input::from_value(&json!({
            "cost": {"total_cost_usd": "x", "total_duration_ms": "a[$(touch x)]",
                     "total_lines_added": "\u{1b}[31mINJ\nX", "total_lines_removed": 3},
            "context_window": {"used_percentage": "\u{1b}[31mPWNED"},
            "rate_limits": {"five_hour": {"used_percentage": 23.4, "resets_at": "b[$(touch x)]"}}
        }));
        assert_eq!(input.cost, 0.0);
        assert_eq!(input.duration_ms, 0);
        assert_eq!(input.lines_added, 0);
        assert_eq!(input.lines_removed, 3);
        assert_eq!(input.ctx_pct, 0);
        assert_eq!(input.five_hour, Some(23.4));
        assert_eq!(input.five_hour_reset, None);
    }

    #[test]
    fn zero_reset_is_a_known_value_and_empty_percent_is_absent() {
        let input = Input::from_value(&json!({"rate_limits": {
            "five_hour": {"used_percentage": 0, "resets_at": 0},
            "seven_day": {"used_percentage": "", "resets_at": null}
        }}));
        assert_eq!(input.five_hour, Some(0.0));
        assert_eq!(input.five_hour_reset, Some(0));
        assert_eq!(input.week, None);
        assert_eq!(input.week_reset, None);
    }

    #[test]
    fn invalid_json_knows_nothing() {
        assert_eq!(Input::parse("not json"), Input::default());
    }
}
