//! Fuzz target for luagate_extract_sni and luagate_detect_protocol.
//!
//! Feeds arbitrary byte sequences as TLS ClientHello data and verifies
//! no panics, parsing errors, or boundary violations occur.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut sni_buf = vec![0i8; 512];
    let mut sni_len: usize = 0;

    // Fuzz SNI extraction
    let _ = luagate_stream::luagate_extract_sni(
        data.as_ptr() as *const i8,
        data.len(),
        sni_buf.as_mut_ptr(),
        sni_buf.len(),
        &mut sni_len,
    );

    // Fuzz protocol detection
    let mut proto_buf = vec![0i8; 16];
    let mut proto_len: usize = 0;
    let _ = luagate_stream::luagate_detect_protocol(
        data.as_ptr() as *const i8,
        data.len(),
        proto_buf.as_mut_ptr(),
        proto_buf.len(),
        &mut proto_len,
    );
});
