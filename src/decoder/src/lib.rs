// luagate_decoder: Multi-layer URL decoder Rust cdylib
//
// ABI contract (docs/spec/c-ffi-modules.md §5):
//   - caller-allocated output buffers (no Rust malloc returned to caller)
//   - NULL pointer input → LUAGATE_INVALID_INPUT (-1), no panic
//   - LUAGATE_INVALID_INPUT with partial output: decode_partial semantics
//   - panic = "abort" in release profile (see Cargo.toml)
//   - 5ms budget enforced per call

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

/// Budget: 5 ms per FFI call
const BUDGET_NS: u128 = 5_000_000;

// ── Internal helpers ─────────────────────────────────────────────────────────

/// Write `src` into `out[..out_cap]`. Sets `*out_len` to bytes written.
/// Returns LUAGATE_BUFFER_TOO_SMALL if src.len() > out_cap.
unsafe fn write_output(src: &[u8], out: *mut i8, out_cap: usize, out_len: *mut usize) -> i32 {
    if src.len() > out_cap {
        // Write as many bytes as fit so caller can see partial content length
        let n = out_cap;
        std::ptr::copy_nonoverlapping(src.as_ptr(), out as *mut u8, n);
        *out_len = n;
        return LUAGATE_BUFFER_TOO_SMALL;
    }
    std::ptr::copy_nonoverlapping(src.as_ptr(), out as *mut u8, src.len());
    *out_len = src.len();
    LUAGATE_OK
}

/// Apply NFKC normalization and remove null bytes / ASCII control characters.
fn nfkc_and_sanitize(input: &str) -> String {
    input
        .nfkc()
        .filter(|c| !c.is_control() || *c == '\t' || *c == '\n' || *c == '\r')
        .filter(|c| *c != '\0')
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

    // Step 1: percent-decode (lossy on invalid sequences)
    let decoded_bytes = percent_decode(input_bytes);
    let decoded_str_result = decoded_bytes.decode_utf8();

    let (decoded_str, had_invalid): (std::borrow::Cow<str>, bool) = match decoded_str_result {
        Ok(s) => (s, false),
        Err(_) => {
            // Partial: use lossy UTF-8 conversion and signal invalid input
            let lossy = percent_decode(input_bytes).decode_utf8_lossy();
            (std::borrow::Cow::Owned(lossy.into_owned()), true)
        }
    };

    // Budget check after decode
    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    // Step 2: path segment normalization (resolve .., ., //)
    let normalized_path = normalize_segments(&decoded_str);

    // Budget check after segment normalization
    if budget_start.elapsed().as_nanos() > BUDGET_NS {
        return LUAGATE_BUDGET_EXCEEDED;
    }

    // Step 3: NFKC normalization + null/control removal
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

    // Convert raw bytes to str (lossy)
    let input_str = match std::str::from_utf8(input_bytes) {
        Ok(s) => std::borrow::Cow::Borrowed(s),
        Err(_) => std::borrow::Cow::Owned(String::from_utf8_lossy(input_bytes).into_owned()),
    };

    let mut had_invalid = false;
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

        // Decode key (+ → space)
        let key_bytes: Vec<u8> = key_raw
            .bytes()
            .map(|b| if b == b'+' { b' ' } else { b })
            .collect();
        let decoded_key = percent_decode(&key_bytes).decode_utf8();
        let key_str = match decoded_key {
            Ok(s) => s.into_owned(),
            Err(_) => {
                had_invalid = true;
                percent_decode(&key_bytes)
                    .decode_utf8_lossy()
                    .into_owned()
            }
        };

        result.push_str(&key_str);

        if let Some(val_raw) = value_raw {
            result.push('=');

            // Decode value (+ → space)
            let val_bytes: Vec<u8> = val_raw
                .bytes()
                .map(|b| if b == b'+' { b' ' } else { b })
                .collect();
            let decoded_val = percent_decode(&val_bytes).decode_utf8();
            let val_str = match decoded_val {
                Ok(s) => s.into_owned(),
                Err(_) => {
                    had_invalid = true;
                    percent_decode(&val_bytes)
                        .decode_utf8_lossy()
                        .into_owned()
                }
            };
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
}
