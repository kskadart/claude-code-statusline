//! The unofficial OAuth usage endpoint: fetching and caching its response, and
//! reading values out of it.
//!
//! `security` and `curl` are external commands on purpose: the binary stays
//! small, with no TLS stack of its own, and tests can stub them through `PATH`.

use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::SystemTime;

use chrono::NaiveDateTime;
use serde_json::Value;

use crate::input::{lookup, percent, truthy};

const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const PRIVATE_MODE: u32 = 0o600;

pub struct UsageCache {
    path: PathBuf,
    max_age_secs: i64,
}

impl UsageCache {
    pub fn new(dir: &Path, max_age_secs: i64) -> Self {
        Self {
            path: dir.join("statusline-ratelimit.json"),
            max_age_secs,
        }
    }

    fn sibling(&self, suffix: &str) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(suffix);
        PathBuf::from(name)
    }

    /// Refreshes the cache unless it, or the marker of a recent failure, is
    /// still fresh. A failed fetch keeps any older cache in place.
    pub fn refresh(&self) {
        let fail_marker = self.sibling(".fail");
        if self.is_fresh(&self.path) || self.is_fresh(&fail_marker) {
            return;
        }
        if let Some(dir) = self.path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if self.fetch().is_some() {
            let _ = fs::remove_file(&fail_marker);
        } else {
            write_fail_marker(&fail_marker);
        }
    }

    fn is_fresh(&self, path: &Path) -> bool {
        let Ok(meta) = fs::metadata(path) else {
            return false;
        };
        let Ok(modified) = meta.modified() else {
            return false;
        };
        meta.is_file() && age_secs(modified) <= self.max_age_secs
    }

    fn fetch(&self) -> Option<()> {
        let token = read_token()?;
        let tmp = self.sibling(".tmp");
        let accepted = download(&token, &tmp).is_some()
            && fs::read(&tmp).is_ok_and(|body| is_usage_response(&body));
        if accepted && fs::rename(&tmp, &self.path).is_ok() {
            return Some(());
        }
        let _ = fs::remove_file(&tmp);
        None
    }

    /// The cached response, if there is one. Unparsable content reads as null.
    pub fn read(&self) -> Option<Value> {
        let text = fs::read_to_string(&self.path).ok()?;
        Some(serde_json::from_str(&text).unwrap_or(Value::Null))
    }
}

fn age_secs(modified: SystemTime) -> i64 {
    match SystemTime::now().duration_since(modified) {
        Ok(age) => i64::try_from(age.as_secs()).unwrap_or(i64::MAX),
        Err(_) => 0,
    }
}

fn read_token() -> Option<String> {
    let user = env::var("USER").unwrap_or_default();
    let output = Command::new("security")
        .args(["find-generic-password", "-a", &user])
        .args(["-s", KEYCHAIN_SERVICE, "-w"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let credentials: Value = serde_json::from_slice(&output.stdout).ok()?;
    lookup(&credentials, &["claudeAiOauth", "accessToken"])?
        .as_str()
        .filter(|token| !token.is_empty())
        .map(str::to_string)
}

fn download(token: &str, tmp: &Path) -> Option<()> {
    let config = curl_auth_config(token)?;
    let file = private_file(tmp).ok()?;
    file.set_permissions(fs::Permissions::from_mode(PRIVATE_MODE))
        .ok()?;
    let mut curl = Command::new("curl")
        .args(["-s", "--max-time", "2", "--config", "-"])
        .args(["-H", "anthropic-beta: oauth-2025-04-20", USAGE_URL])
        .stdin(Stdio::piped())
        .stdout(file)
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    // Dropping stdin closes it, which is what lets curl stop reading its config.
    if let Some(mut stdin) = curl.stdin.take() {
        let _ = stdin.write_all(config.as_bytes());
    }
    curl.wait().ok()?;
    Some(())
}

/// The auth header as a curl config file. It goes over stdin because command
/// line arguments are visible to every local user through `ps`. A token with
/// control characters isn't a real one and could smuggle in extra config lines.
fn curl_auth_config(token: &str) -> Option<String> {
    if token.chars().any(char::is_control) {
        return None;
    }
    let escaped = token.replace('\\', "\\\\").replace('"', "\\\"");
    Some(format!("header = \"Authorization: Bearer {escaped}\"\n"))
}

fn private_file(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(PRIVATE_MODE)
        .open(path)
}

/// Sets the mtime explicitly: truncating an already-empty file need not update
/// it, and a stale marker would stop backing off.
fn write_fail_marker(path: &Path) {
    if let Ok(file) = private_file(path) {
        let _ = file.set_permissions(fs::Permissions::from_mode(PRIVATE_MODE));
        let _ = file.set_modified(SystemTime::now());
    }
}

/// Validates the response's shape, not a value: `five_hour` is legitimately
/// null in an otherwise good response, and error bodies have neither key.
fn is_usage_response(body: &[u8]) -> bool {
    serde_json::from_slice::<Value>(body)
        .ok()
        .as_ref()
        .and_then(Value::as_object)
        .is_some_and(|object| object.contains_key("five_hour") || object.contains_key("limits"))
}

/// Parses `YYYY-MM-DDTHH:MM:SS...` as UTC, ignoring anything after the seconds.
pub fn iso_to_epoch(iso: &str) -> Option<i64> {
    let parsed = NaiveDateTime::parse_from_str(iso.get(..19)?, "%Y-%m-%dT%H:%M:%S").ok()?;
    Some(parsed.and_utc().timestamp())
}

/// The all-model values from a cached response, used when stdin has none.
pub struct Fallback {
    pub five_hour: Option<f64>,
    /// `None`: the response names no reset. `Some(None)`: it names an
    /// unparsable one, which replaces any value from stdin.
    pub five_hour_reset: Option<Option<i64>>,
    pub week: Option<f64>,
    pub week_reset: Option<Option<i64>>,
}

pub fn fallback_values(response: &Value) -> Fallback {
    let reset = |path: &[&str]| truthy(response, path).map(|iso| iso_to_epoch(&iso));
    Fallback {
        five_hour: percent(response, &["five_hour", "utilization"]),
        five_hour_reset: reset(&["five_hour", "resets_at"]),
        week: percent(response, &["seven_day", "utilization"]),
        week_reset: reset(&["seven_day", "resets_at"]),
    }
}

/// The first `weekly_scoped` row whose model matches, as (percent, reset).
/// The endpoint's name ("Fable") is a prefix of the display name ("Fable 5.1");
/// without a display name, the id ("claude-fable-5-1") has to contain it.
pub fn model_limit(response: &Value, display: &str, id: &str) -> Option<(f64, Option<i64>)> {
    let display = display.to_ascii_lowercase();
    let id = id.to_ascii_lowercase();
    let matches = |row: &Value| {
        let name = lookup(row, &["scope", "model", "display_name"])
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        !name.is_empty()
            && if display.is_empty() {
                id.contains(&name)
            } else {
                display.starts_with(&name)
            }
    };

    let row = lookup(response, &["limits"])?
        .as_array()?
        .iter()
        .find(|row| {
            lookup(row, &["kind"]).and_then(Value::as_str) == Some("weekly_scoped")
                && matches(row)
                && lookup(row, &["percent"]).is_some_and(Value::is_number)
        })?;
    let pct = lookup(row, &["percent"])?.as_f64()?.clamp(0.0, 999.0);
    let reset = truthy(row, &["resets_at"]).and_then(|iso| iso_to_epoch(&iso));
    Some((pct, reset))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row(name: &str, pct: Value) -> Value {
        json!({"kind": "weekly_scoped", "percent": pct,
               "resets_at": "2099-01-01T00:00:00.000000+00:00",
               "scope": {"model": {"display_name": name}}})
    }

    #[test]
    fn curl_auth_config_quotes_the_token_and_rejects_control_characters() {
        assert_eq!(
            curl_auth_config("abc-123").unwrap(),
            "header = \"Authorization: Bearer abc-123\"\n"
        );
        assert_eq!(
            curl_auth_config(r#"a"b\c"#).unwrap(),
            "header = \"Authorization: Bearer a\\\"b\\\\c\"\n"
        );
        assert_eq!(curl_auth_config("abc\nurl = \"http://evil\""), None);
    }

    #[test]
    fn iso_to_epoch_reads_utc_and_rejects_garbage() {
        assert_eq!(iso_to_epoch("1970-01-01T00:01:00.000000+00:00"), Some(60));
        assert_eq!(iso_to_epoch("2099-01-01T00:00:00"), Some(4_070_908_800));
        for bad in [
            "",
            "soon",
            "2099-01-01",
            "2099-13-01T00:00:00",
            "ééééééééééééééééééééé",
        ] {
            assert_eq!(iso_to_epoch(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn usage_response_shape() {
        assert!(is_usage_response(br#"{"five_hour": null}"#));
        assert!(is_usage_response(br#"{"limits": []}"#));
        for bad in [
            &br#"{"type":"error","error":{}}"#[..],
            b"not json",
            b"[]",
            b"",
        ] {
            assert!(!is_usage_response(bad));
        }
    }

    #[test]
    fn display_name_matches_by_prefix_case_insensitively() {
        let response = json!({"limits": [row("Opus", json!(55)), row("Fable", json!(80))]});
        let (pct, reset) = model_limit(&response, "FABLE 5.1", "ignored-opus").unwrap();
        assert_eq!(pct, 80.0);
        assert_eq!(reset, Some(4_070_908_800));
    }

    #[test]
    fn id_is_only_used_without_a_display_name() {
        let response = json!({"limits": [row("Sonnet", json!(42))]});
        assert_eq!(
            model_limit(&response, "", "claude-sonnet-5").unwrap().0,
            42.0
        );
        assert!(model_limit(&response, "Haiku 4.5", "claude-sonnet-5").is_none());
    }

    #[test]
    fn rows_of_another_kind_or_without_a_numeric_percent_are_skipped() {
        let response = json!({"limits": [
            {"kind": "weekly_all", "percent": 44},
            row("Fable", json!("80")),
            row("Fable", json!(81)),
        ]});
        assert_eq!(model_limit(&response, "Fable 5.1", "").unwrap().0, 81.0);
    }

    #[test]
    fn percent_is_clamped_and_bad_limits_are_absent() {
        let response = json!({"limits": [row("Fable", json!(5000))]});
        assert_eq!(model_limit(&response, "Fable", "").unwrap().0, 999.0);
        let response = json!({"limits": [row("Fable", json!(-3))]});
        assert_eq!(model_limit(&response, "Fable", "").unwrap().0, 0.0);
        assert!(model_limit(&json!({"limits": "x"}), "Fable", "").is_none());
        assert!(model_limit(&json!({}), "Fable", "").is_none());
    }

    #[test]
    fn fallback_tolerates_null_five_hour() {
        let values = fallback_values(&json!({
            "five_hour": null,
            "seven_day": {"utilization": 12, "resets_at": "1970-01-01T00:01:00+00:00"}
        }));
        assert_eq!(values.five_hour, None);
        assert_eq!(values.five_hour_reset, None);
        assert_eq!(values.week, Some(12.0));
        assert_eq!(values.week_reset, Some(Some(60)));
    }

    #[test]
    fn fallback_marks_an_unparsable_reset() {
        let values = fallback_values(&json!({"seven_day": {"resets_at": "soon"}}));
        assert_eq!(values.week_reset, Some(None));
    }
}
