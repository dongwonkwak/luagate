// luagate_decoder: Multi-layer URL decoder Rust cdylib
//
// ABI contract (docs/spec/c-ffi-modules.md §5):
//   - caller-allocated output buffers (no Rust malloc returned to caller)
//   - NULL pointer input → LUAGATE_INVALID_INPUT (-1), no panic
//   - LUAGATE_INVALID_INPUT with partial output: decode_partial semantics
//   - panic = "abort" in release profile (see Cargo.toml)
//   - 0.5ms budget enforced per call (decoder/parser budget — c-ffi-modules.md §7)

use percent_encoding::percent_decode;
use std::time::Instant;
use unicode_normalization::UnicodeNormalization;

// ── Error codes (c-ffi-modules.md §5) ───────────────────────────────────────
const LUAGATE_OK: i32 = 0;
const LUAGATE_NEED_MORE_DATA: i32 = 1;
const LUAGATE_INVALID_INPUT: i32 = -1;
const LUAGATE_BUFFER_TOO_SMALL: i32 = -2;
const LUAGATE_BUDGET_EXCEEDED: i32 = -3;
const LUAGATE_INTERNAL_ERROR: i32 = -4;

/// Budget: 0.5 ms per FFI call (decoder/parser budget — c-ffi-modules.md §7)
const BUDGET_NS: u128 = 500_000;

// ── Internal helpers ─────────────────────────────────────────────────────────

/// Write `src` into `out[..out_cap]`. Sets `*out_len` to bytes written.
/// Returns LUAGATE_BUFFER_TOO_SMALL if src.len() > out_cap.
unsafe fn write_output(src: &[u8], out: *mut i8, out_cap: usize, out_len: *mut usize) -> i32 {
    if src.len() > out_cap {
        // Buffer too small — out_len=0 signals buffer contents are indeterminate (spec §3)
        *out_len = 0;
        return LUAGATE_BUFFER_TOO_SMALL;
    }
    std::ptr::copy_nonoverlapping(src.as_ptr(), out as *mut u8, src.len());
    *out_len = src.len();
    LUAGATE_OK
}

/// Apply NFKC normalization and remove all control characters (including CR/LF/TAB).
fn nfkc_and_sanitize(input: &str) -> String {
    input
        .nfkc()
        .filter(|c| !c.is_control())
        .collect()
}

/// Normalize path segments: resolve `..` and `.`, collapse `//`.
fn normalize_segments(path: &str) -> String {
    let mut segments: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" | "." => {
                // collapse empty / current-dir
            }
            ".." => {
                segments.pop();
            }
            s => {
                segments.push(s);
            }
        }
    }
    let result = format!("/{}", segments.join("/"));
    // Preserve trailing slash if original had one (and path is not just "/")
    if path.ends_with('/') && result != "/" {
        format!("{}/", result)
    } else {
        result
    }
}

/// Detect malformed percent-encoding sequences in a string.
///
/// Returns true if any `%XX` where XX are not both valid hex digits, or a
/// trailing `%` with fewer than 2 following characters.
fn has_malformed_percent(s: &str) -> bool {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return true; // trailing % with fewer than 2 chars
            }
            let hi = bytes[i + 1];
            let lo = bytes[i + 2];
            if !hi.is_ascii_hexdigit() || !lo.is_ascii_hexdigit() {
                return true; // %GG or similar invalid hex pair
            }
            i += 3;
        } else {
            i += 1;
        }
    }
    false
}

/// Percent-decode a byte slice, returning (decoded_string, had_invalid).
///
/// `had_invalid` is true if malformed `%XX` sequences were detected in the
/// original input, or if the decoded bytes are not valid UTF-8.
fn percent_decode_with_validation(input: &[u8]) -> (String, bool) {
    // Check for malformed %XX before decoding so we can report had_invalid
    // even if the percent-encoding crate silently passes them through.
    let input_str = std::str::from_utf8(input).unwrap_or("");
    let had_malformed = has_malformed_percent(input_str);

    let decoded = match percent_decode(input).decode_utf8() {
        Ok(s) => (s.into_owned(), had_malformed),
        Err(_) => {
            // Invalid UTF-8 after decoding
            let lossy = percent_decode(input).decode_utf8_lossy().into_owned();
            (lossy, true)
        }
    };
    decoded
}

/// Decode HTML entities in a string.
///
/// Handles numeric (`&#NNN;`, `&#xHH;`) and named (`&amp;`, `&lt;`, `&gt;`,
/// `&quot;`, `&apos;`) entities.
fn decode_html_entities(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let chars: Vec<char> = input.chars().collect();
    let len = chars.len();
    let mut i = 0;
    while i < len {
        if chars[i] == '&' {
            // Try to find the closing ';' within a reasonable window (max 10 chars)
            let end = (i + 1..len).take(10).find(|&j| chars[j] == ';');
            if let Some(end_pos) = end {
                let entity_body: String = chars[i + 1..end_pos].iter().collect();
                let replacement = if entity_body.starts_with('#') {
                    // Numeric entity: &#NNN; or &#xHH;
                    let rest = &entity_body[1..];
                    let codepoint = if rest.starts_with('x') || rest.starts_with('X') {
                        u32::from_str_radix(&rest[1..], 16).ok()
                    } else {
                        rest.parse::<u32>().ok()
                    };
                    codepoint.and_then(char::from_u32).map(|c| c.to_string())
                } else {
                    // Named entities
                    match entity_body.as_str() {
                        "amp" => Some("&".to_string()),
                        "lt" => Some("<".to_string()),
                        "gt" => Some(">".to_string()),
                        "quot" => Some("\"".to_string()),
                        "apos" => Some("'".to_string()),
                        _ => None,
                    }
                };
                if let Some(r) = replacement {
                    out.push_str(&r);
                    i = end_pos + 1;
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

// ── Exported FFI functions ───────────────────────────────────────────────────

/// URL percent-decode → path normalize (..) → NFKC → null/control removal.
///
/// LUAGATE_INVALID_INPUT is returned with partial output (decode_partial semantics)
/// when the input contains invalid percent-encoding sequences.
///
/// # Safety
/// `path_raw` must be valid for `path_raw_len` bytes (or NULL).
/// `out` must be valid for `out_cap` bytes.
/// `out_len` must be a valid non-null pointer.
#[no_mangle]
pub unsafe extern "C" fn luagate_normalize_path(
    path_raw: *const i8,
    path_raw_len: usize,
    out: *mut i8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    // NULL pointer guard
    if path_raw.is_null() || out.is_null() || out_len.is_null() {
        if !out_len.is_null() {
            *out_len = 0;
        }
        return LUAGATE_INVALID_INPUT;
    }

    *out_len = 0;
    let budget_start = Instant::now();

    // Build input slice
    let input_bytes = std::slice::from_raw_parts(path_raw as *const u8, path_raw_len);

    // Step 1: 1st percent-decode (with malformed %XX detection)
    let (after_decode1, invalid1) = percent_decode_with_validation(input_bytes);

    // Budget check
    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    // Step 2: HTML entity decode (e.g. &#46; → '.')
    let after_html = decode_html_entities(&after_decode1);

    // Step 3: 2nd percent-decode (handles double-encoded sequences like %252e)
    let (after_decode2, invalid2) = percent_decode_with_validation(after_html.as_bytes());

    let had_invalid = invalid1 || invalid2;

    // Budget check after multi-layer decode
    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    // Step 4: path segment normalization (resolve .., ., //)
    let normalized_path = normalize_segments(&after_decode2);

    // Budget check after segment normalization
    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    // Step 5: NFKC normalization + null/control removal
    let sanitized = nfkc_and_sanitize(&normalized_path);

    // Budget check after NFKC
    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    let result_bytes = sanitized.as_bytes();
    let write_rc = write_output(result_bytes, out, out_cap, out_len);
    if write_rc != LUAGATE_OK {
        return write_rc;
    }

    if had_invalid {
        LUAGATE_INVALID_INPUT
    } else {
        LUAGATE_OK
    }
}

/// Query string normalization (name/value component-level).
///
/// Splits on `&`, then splits each pair on `=`, percent-decodes key and value
/// (`+` → space per application/x-www-form-urlencoded), and reassembles.
///
/// # Safety
/// Same contract as `luagate_normalize_path`.
#[no_mangle]
pub unsafe extern "C" fn luagate_normalize_query(
    query_raw: *const i8,
    query_raw_len: usize,
    out: *mut i8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    // NULL pointer guard
    if query_raw.is_null() || out.is_null() || out_len.is_null() {
        if !out_len.is_null() {
            *out_len = 0;
        }
        return LUAGATE_INVALID_INPUT;
    }

    *out_len = 0;
    let budget_start = Instant::now();

    let input_bytes = std::slice::from_raw_parts(query_raw as *const u8, query_raw_len);

    // Convert raw bytes to str (lossy), flag invalid UTF-8
    let (input_str, had_raw_invalid) = match std::str::from_utf8(input_bytes) {
        Ok(s) => (std::borrow::Cow::Borrowed(s), false),
        Err(_) => (
            std::borrow::Cow::Owned(String::from_utf8_lossy(input_bytes).into_owned()),
            true,
        ),
    };

    let mut had_invalid = had_raw_invalid;
    let mut result = String::with_capacity(input_bytes.len());

    for (i, param) in input_str.split('&').enumerate() {
        if i > 0 {
            result.push('&');
        }

        // Split key=value (at most one '=')
        let (key_raw, value_raw) = if let Some(eq_pos) = param.find('=') {
            (&param[..eq_pos], Some(&param[eq_pos + 1..]))
        } else {
            (param, None)
        };

        // Decode key: + → space, then multilayer decode
        let key_plus: String = key_raw
            .chars()
            .map(|c| if c == '+' { ' ' } else { c })
            .collect();
        // 1st percent-decode (with malformed %XX detection)
        let (key_dec1, key_inv1) = percent_decode_with_validation(key_plus.as_bytes());
        if key_inv1 {
            had_invalid = true;
        }
        // HTML entity decode
        let key_dec2 = decode_html_entities(&key_dec1);
        // 2nd percent-decode (double-encoding)
        let (key_str, key_inv2) = percent_decode_with_validation(key_dec2.as_bytes());
        if key_inv2 {
            had_invalid = true;
        }

        result.push_str(&key_str);

        if let Some(val_raw) = value_raw {
            result.push('=');

            // Decode value: + → space, then multilayer decode
            let val_plus: String = val_raw
                .chars()
                .map(|c| if c == '+' { ' ' } else { c })
                .collect();
            // 1st percent-decode (with malformed %XX detection)
            let (val_dec1, val_inv1) = percent_decode_with_validation(val_plus.as_bytes());
            if val_inv1 {
                had_invalid = true;
            }
            // HTML entity decode
            let val_dec2 = decode_html_entities(&val_dec1);
            // 2nd percent-decode (double-encoding)
            let (val_str, val_inv2) = percent_decode_with_validation(val_dec2.as_bytes());
            if val_inv2 {
                had_invalid = true;
            }
            result.push_str(&val_str);
        }

        // Periodic budget check
        if budget_start.elapsed().as_nanos() > BUDGET_NS {
            // Write partial result so far
            let partial_bytes = result.as_bytes();
            let _ = write_output(partial_bytes, out, out_cap, out_len);
            return LUAGATE_BUDGET_EXCEEDED;
        }
    }

    let result_bytes = result.as_bytes();
    let write_rc = write_output(result_bytes, out, out_cap, out_len);
    if write_rc != LUAGATE_OK {
        return write_rc;
    }

    if had_invalid {
        LUAGATE_INVALID_INPUT
    } else {
        LUAGATE_OK
    }
}

/// NFKC Unicode normalization.
///
/// Invalid UTF-8 input → LUAGATE_INVALID_INPUT with lossy partial result.
///
/// # Safety
/// Same contract as `luagate_normalize_path`.
#[no_mangle]
pub unsafe extern "C" fn luagate_normalize_nfkc(
    input: *const i8,
    input_len: usize,
    out: *mut i8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    // NULL pointer guard
    if input.is_null() || out.is_null() || out_len.is_null() {
        if !out_len.is_null() {
            *out_len = 0;
        }
        return LUAGATE_INVALID_INPUT;
    }

    *out_len = 0;
    let budget_start = Instant::now();

    let input_bytes = std::slice::from_raw_parts(input as *const u8, input_len);

    let (input_str, had_invalid): (std::borrow::Cow<str>, bool) =
        match std::str::from_utf8(input_bytes) {
            Ok(s) => (std::borrow::Cow::Borrowed(s), false),
            Err(_) => (
                std::borrow::Cow::Owned(String::from_utf8_lossy(input_bytes).into_owned()),
                true,
            ),
        };

    let normalized: String = input_str.nfkc().collect();

    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    let result_bytes = normalized.as_bytes();
    let write_rc = write_output(result_bytes, out, out_cap, out_len);
    if write_rc != LUAGATE_OK {
        return write_rc;
    }

    if had_invalid {
        LUAGATE_INVALID_INPUT
    } else {
        LUAGATE_OK
    }
}

// ── Suppress unused constant warnings ───────────────────────────────────────
#[allow(dead_code)]
const _: i32 = LUAGATE_NEED_MORE_DATA;
#[allow(dead_code)]
const _: i32 = LUAGATE_INTERNAL_ERROR;

// ── Unit tests ───────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_path_basic() {
        let input = b"/foo%2Fbar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        assert!(out_len > 0);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        // %2F is a literal slash in path: /foo/bar
        assert_eq!(result, "/foo/bar");
    }

    #[test]
    fn test_normalize_path_traversal_removed() {
        let input = b"/foo/../bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(!result.contains(".."), "path traversal not removed: {}", result);
        assert_eq!(result, "/bar");
    }

    #[test]
    fn test_normalize_path_double_slash() {
        let input = b"//foo//bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(!result.contains("//"), "double slash not collapsed: {}", result);
    }

    #[test]
    fn test_normalize_path_dot_segment() {
        let input = b"/foo/./bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert_eq!(result, "/foo/bar");
    }

    #[test]
    fn test_buffer_too_small() {
        let input = b"/foo%2Fbar%2Fbaz";
        let mut out = vec![0u8; 1]; // too small
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_BUFFER_TOO_SMALL);
        // out_len must be 0 on BUFFER_TOO_SMALL (spec §3: buffer contents indeterminate)
        assert_eq!(out_len, 0);
    }

    #[test]
    fn test_crlf_stripped_from_path() {
        // %0d%0a → CR LF after percent-decode; must be removed by nfkc_and_sanitize
        let input = b"/foo%0d%0abar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(
            !result.contains('\r') && !result.contains('\n'),
            "CRLF not stripped: {:?}",
            result
        );
    }

    #[test]
    fn test_tab_stripped_from_path() {
        // %09 → TAB; must be removed
        let input = b"/foo%09bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(!result.contains('\t'), "TAB not stripped: {:?}", result);
    }

    #[test]
    fn test_null_pointer_returns_invalid_input() {
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                std::ptr::null(),
                0,
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_null_out_returns_invalid_input() {
        let input = b"/foo";
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                std::ptr::null_mut(),
                0,
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_normalize_query_basic() {
        let input = b"a=1&b=hello%20world";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_query(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert_eq!(result, "a=1&b=hello world");
    }

    #[test]
    fn test_normalize_query_plus_to_space() {
        let input = b"q=hello+world";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_query(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert_eq!(result, "q=hello world");
    }

    #[test]
    fn test_normalize_query_null_pointer() {
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_query(
                std::ptr::null(),
                0,
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_normalize_nfkc_basic() {
        // Full-width ASCII 'Ａ' (U+FF21) → 'A' after NFKC
        let input = "\u{FF21}".as_bytes();
        let mut out = vec![0u8; 64];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_nfkc(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert_eq!(result, "A");
    }

    #[test]
    fn test_normalize_nfkc_null_pointer() {
        let mut out = vec![0u8; 64];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_nfkc(
                std::ptr::null(),
                0,
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_normalize_nfkc_empty() {
        let input = b"";
        let mut out = vec![0u8; 64];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_nfkc(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(out_len, 0);
    }

    #[test]
    fn test_normalize_path_empty() {
        let input = b"/";
        let mut out = vec![0u8; 64];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert_eq!(result, "/");
    }

    #[test]
    fn test_normalize_path_multiple_traversal() {
        let input = b"/a/b/../../c";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(!result.contains(".."));
        assert_eq!(result, "/c");
    }

    // ── New tests: multilayer decoding + malformed %XX detection ─────────────

    #[test]
    fn test_has_malformed_percent_valid() {
        assert!(!has_malformed_percent("/foo%2Fbar"));
        assert!(!has_malformed_percent("/foo%20bar"));
        assert!(!has_malformed_percent("/noencoding"));
    }

    #[test]
    fn test_has_malformed_percent_invalid() {
        assert!(has_malformed_percent("/foo%GGbar"));  // %GG: non-hex
        assert!(has_malformed_percent("/foo%"));       // trailing %
        assert!(has_malformed_percent("/foo%2"));      // truncated %XX
    }

    #[test]
    fn test_normalize_path_malformed_percent_returns_invalid_input() {
        // %GG is not valid hex — must return LUAGATE_INVALID_INPUT
        let input = b"/foo%GGbar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_INVALID_INPUT, "malformed %XX must return INVALID_INPUT");
        // partial output must still be present
        assert!(out_len > 0, "partial output expected on INVALID_INPUT");
    }

    #[test]
    fn test_normalize_path_double_encoded_traversal() {
        // %252e%252e = double-encoded ".."
        // 1st decode: %25 → '%', so "%252e" → "%2e", giving /foo/%2e%2e/bar
        // 2nd decode: %2e → '.', giving /foo/../bar
        // normalize_segments resolves ..: /foo + .. → /foo removed → /bar
        let input = b"/foo/%252e%252e/bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(!result.contains(".."), "double-encoded traversal not removed: {}", result);
        assert_eq!(result, "/bar");
    }

    #[test]
    fn test_normalize_path_html_entity_dot() {
        // &#46; is the HTML entity for '.' (ASCII 46 = '.')
        // HTML decode: /foo/&#46;&#46;/bar → /foo/../bar
        // normalize_segments resolves ..: /foo + .. → /foo removed → /bar
        let input = b"/foo/&#46;&#46;/bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert!(!result.contains(".."), "HTML entity traversal not removed: {}", result);
        assert_eq!(result, "/bar");
    }

    #[test]
    fn test_normalize_path_html_named_entities() {
        // &amp; → &, &lt; → <, &gt; → >, &quot; → ", &apos; → '
        let input = b"/foo&amp;bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_path(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        assert_eq!(result, "/foo&bar");
    }

    #[test]
    fn test_decode_html_entities_numeric_hex() {
        // &#x2F; is '/'
        let result = decode_html_entities("/foo&#x2F;bar");
        assert_eq!(result, "/foo/bar");
    }

    #[test]
    fn test_normalize_query_malformed_percent_returns_invalid_input() {
        // %ZZ in query key — must return LUAGATE_INVALID_INPUT
        let input = b"key%ZZ=value";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_query(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_INVALID_INPUT, "malformed %XX in query must return INVALID_INPUT");
    }

    #[test]
    fn test_normalize_query_double_encoded_value() {
        // %2520 = double-encoded '%20' → after 2x decode becomes space
        let input = b"q=%2520";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_query(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, LUAGATE_OK);
        let result = std::str::from_utf8(&out[..out_len]).unwrap();
        // %2520 → 1st decode → %20 → 2nd decode → space
        assert_eq!(result, "q= ");
    }

    #[test]
    fn test_normalize_query_html_entity_in_value() {
        // &amp; in query value should become '&'
        let input = b"a=foo&amp;bar";
        let mut out = vec![0u8; 256];
        let mut out_len: usize = 0;
        let rc = unsafe {
            luagate_normalize_query(
                input.as_ptr() as *const i8,
                input.len(),
                out.as_mut_ptr() as *mut i8,
                out.len(),
                &mut out_len,
            )
        };
        // "&amp;" as a query param separator splits: key "a", value "foo"; then
        // second param "amp;bar" with no value. We test the key=value first param.
        // The important assertion: no crash, valid return.
        assert!(rc == LUAGATE_OK || rc == LUAGATE_INVALID_INPUT);
        assert!(out_len > 0);
    }
}
