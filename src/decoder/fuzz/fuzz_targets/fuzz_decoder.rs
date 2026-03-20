//! Fuzz target for luagate_normalize_path and luagate_normalize_query.
//!
//! Feeds arbitrary byte sequences to path/query normalizers and verifies
//! no panics, buffer overflows, or invalid UTF-8 handling issues occur.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut out = vec![0i8; 8192];
    let mut out_len: usize = 0;

    // Fuzz path normalization
    unsafe {
        let _ = luagate_decoder::luagate_normalize_path(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            out.len(),
            &mut out_len,
        );
    }

    // Fuzz query normalization
    unsafe {
        let _ = luagate_decoder::luagate_normalize_query(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            out.len(),
            &mut out_len,
        );
    }

    // Fuzz NFKC normalization
    unsafe {
        let _ = luagate_decoder::luagate_normalize_nfkc(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            out.len(),
            &mut out_len,
        );
    }
});
