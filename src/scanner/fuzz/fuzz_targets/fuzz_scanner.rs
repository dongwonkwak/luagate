//! Fuzz target for luagate_scan_http.
//!
//! Feeds arbitrary byte sequences as path/query strings to the scanner
//! and verifies no panics, memory errors, or infinite loops occur.
//! The scanner must be initialised before fuzzing (uses hardcoded patterns).

#![no_main]

use libfuzzer_sys::fuzz_target;

static INIT: std::sync::Once = std::sync::Once::new();

fuzz_target!(|data: &[u8]| {
    INIT.call_once(|| {
        luagate_scanner::luagate_scanner_init(std::ptr::null(), 0);
    });

    // Split fuzz input into path and query at midpoint
    let mid = data.len() / 2;
    let path = &data[..mid];
    let query = &data[mid..];

    let mut threat_buf = vec![0i8; 128];
    let mut rule_buf = vec![0i8; 128];
    let mut threat_len: usize = 0;
    let mut rule_len: usize = 0;
    let mut score: f64 = 0.0;

    let _ = luagate_scanner::luagate_scan_http(
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
        threat_buf.len(),
        &mut threat_len,
        rule_buf.as_mut_ptr(),
        rule_buf.len(),
        &mut rule_len,
        &mut score,
    );
});
