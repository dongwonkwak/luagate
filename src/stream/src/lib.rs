// luagate_stream — Protocol detection, TLS SNI extraction, CIDR radix tree.
//
// ABI contract: docs/spec/rust-ffi-modules.md §6
// All functions use the common luagate_result error codes.
//
// All public extern "C" functions accept raw pointers from C callers.
// The Safety contract is documented per-function; the clippy lint is suppressed
// at the crate level to match the pattern used by luagate_scanner and luagate_decoder.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::net::Ipv4Addr;

// Return codes (ABI contract — docs/spec/rust-ffi-modules.md §2)
const LUAGATE_OK: i32 = 0;
const LUAGATE_NEED_MORE_DATA: i32 = 1;
const LUAGATE_INVALID_INPUT: i32 = -1;
const LUAGATE_BUFFER_TOO_SMALL: i32 = -2;
#[allow(dead_code)]
const LUAGATE_BUDGET_EXCEEDED: i32 = -3;
const LUAGATE_INTERNAL_ERROR: i32 = -4;

// ---------------------------------------------------------------------------
// Helper: write a byte slice into a caller-allocated output buffer
// ---------------------------------------------------------------------------
unsafe fn write_output(
    data: &[u8],
    out: *mut i8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return LUAGATE_INTERNAL_ERROR;
    }
    if data.len() > out_cap {
        return LUAGATE_BUFFER_TOO_SMALL;
    }
    std::ptr::copy_nonoverlapping(data.as_ptr() as *const i8, out, data.len());
    *out_len = data.len();
    LUAGATE_OK
}

// ---------------------------------------------------------------------------
// Protocol Detection
// ---------------------------------------------------------------------------

/// Known HTTP method prefixes for detection.
/// Note: CONNECT is excluded per spec — MVP does not support CONNECT method.
/// CONNECT-prefixed data will be classified as "raw".
const HTTP_METHODS: &[&[u8]] = &[
    b"GET ",
    b"POST ",
    b"PUT ",
    b"DELETE ",
    b"HEAD ",
    b"OPTIONS ",
    b"PATCH ",
];

/// Detect the application-layer protocol from the first bytes of a connection.
///
/// Writes one of "tls", "http", or "raw" into `protocol_out`.
///
/// # Safety
/// All pointer arguments must be valid for the stated lengths.
#[no_mangle]
pub extern "C" fn luagate_detect_protocol(
    buf: *const i8,
    buf_len: usize,
    protocol_out: *mut i8,
    protocol_cap: usize,
    protocol_len: *mut usize,
) -> i32 {
    if buf.is_null() || buf_len == 0 {
        return LUAGATE_NEED_MORE_DATA;
    }

    let data = unsafe { std::slice::from_raw_parts(buf as *const u8, buf_len) };

    // TLS detection: first byte 0x16 (ContentType: Handshake)
    if data[0] == 0x16 {
        // Need at least 3 bytes: ContentType(1) + Version(2)
        if buf_len < 3 {
            return LUAGATE_NEED_MORE_DATA;
        }
        // Check TLS version: major must be 0x03 (SSL 3.0 / TLS 1.x)
        if data[1] != 0x03 {
            // Starts with 0x16 but not a valid TLS record -> malformed TLS
            return LUAGATE_INVALID_INPUT;
        }
        // Valid TLS record header detected
        return unsafe { write_output(b"tls", protocol_out, protocol_cap, protocol_len) };
    }

    // HTTP detection: check if data starts with a known HTTP method
    for method in HTTP_METHODS {
        if data.len() >= method.len() && &data[..method.len()] == *method {
            return unsafe { write_output(b"http", protocol_out, protocol_cap, protocol_len) };
        }
    }

    // For short buffers that could potentially be an HTTP method prefix,
    // check if we might need more data. The shortest method is "GET " (4 bytes).
    if data.len() < 4 {
        // Could be a partial HTTP method - but also could be raw.
        // If the first bytes look like they could start an HTTP method, ask for more.
        let could_be_http = HTTP_METHODS.iter().any(|m| {
            let check_len = data.len().min(m.len());
            data[..check_len] == m[..check_len]
        });
        if could_be_http {
            return LUAGATE_NEED_MORE_DATA;
        }
    }

    // No TLS, no HTTP -> raw
    unsafe { write_output(b"raw", protocol_out, protocol_cap, protocol_len) }
}

// ---------------------------------------------------------------------------
// TLS SNI Extraction
// ---------------------------------------------------------------------------

/// Extract the SNI (Server Name Indication) from a TLS ClientHello message.
///
/// On success with no SNI extension present, out_len is set to 0 and
/// LUAGATE_OK is returned.
///
/// # Safety
/// All pointer arguments must be valid for the stated lengths.
#[no_mangle]
pub extern "C" fn luagate_extract_sni(
    buf: *const i8,
    buf_len: usize,
    out: *mut i8,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return LUAGATE_INTERNAL_ERROR;
    }
    // Initialise output
    unsafe { *out_len = 0; }

    if buf.is_null() || buf_len == 0 {
        return LUAGATE_NEED_MORE_DATA;
    }

    let data = unsafe { std::slice::from_raw_parts(buf as *const u8, buf_len) };

    match parse_sni(data) {
        SniResult::Ok(ref sni) if sni.is_empty() => {
            // No SNI extension — valid TLS without SNI
            LUAGATE_OK
        }
        SniResult::Ok(ref sni) => {
            unsafe { write_output(sni.as_bytes(), out, out_cap, out_len) }
        }
        SniResult::NeedMoreData => LUAGATE_NEED_MORE_DATA,
        SniResult::Invalid => LUAGATE_INVALID_INPUT,
    }
}

enum SniResult {
    Ok(String),
    NeedMoreData,
    Invalid,
}

/// Reassemble handshake payload from one or more TLS records.
///
/// A ClientHello may be split across multiple consecutive TLS Handshake
/// records (ContentType 0x16).  This function walks all such records in
/// `data`, concatenating their payloads into a single `Vec<u8>`.
///
/// Returns `None` if any record is incomplete (NEED_MORE_DATA) or if the
/// first record is not a valid TLS Handshake record.
///
/// Returns `Err(())` for clearly invalid data (e.g. non-0x03 major version).
fn reassemble_handshake(data: &[u8]) -> Result<Vec<u8>, ReassembleError> {
    // Hard cap: 64KB total handshake payload to prevent memory exhaustion
    // from malicious multi-record TLS data (security review M-1).
    const MAX_HANDSHAKE_PAYLOAD: usize = 65536;

    let mut payload = Vec::new();
    let mut offset = 0;

    // We must see at least one record
    if data.len() < 5 {
        return Err(ReassembleError::NeedMoreData);
    }

    while offset < data.len() {
        // Need at least 5 bytes for record header
        if offset + 5 > data.len() {
            // Partial record header after a complete first record —
            // treat as end-of-records (don't fail, just stop).
            if !payload.is_empty() {
                break;
            }
            return Err(ReassembleError::NeedMoreData);
        }

        let content_type = data[offset];
        // Only concatenate Handshake records (0x16)
        if content_type != 0x16 {
            // If we haven't collected any data yet, this is invalid
            if payload.is_empty() {
                return Err(ReassembleError::Invalid);
            }
            // Otherwise stop — non-handshake record after handshake records
            break;
        }

        // Validate TLS version in record header
        if data[offset + 1] != 0x03 {
            return Err(ReassembleError::Invalid);
        }
        if data[offset + 2] > 0x04 {
            return Err(ReassembleError::Invalid);
        }

        let record_len = u16::from_be_bytes([data[offset + 3], data[offset + 4]]) as usize;
        let record_end = offset + 5 + record_len;

        if record_end > data.len() {
            // Incomplete record
            if payload.is_empty() {
                return Err(ReassembleError::NeedMoreData);
            }
            // Partial second+ record — stop and try with what we have
            break;
        }

        payload.extend_from_slice(&data[offset + 5..record_end]);
        offset = record_end;

        // Enforce hard cap (security review M-1)
        if payload.len() > MAX_HANDSHAKE_PAYLOAD {
            return Err(ReassembleError::Invalid);
        }
    }

    Ok(payload)
}

enum ReassembleError {
    NeedMoreData,
    Invalid,
}

/// Parse TLS ClientHello to extract SNI.
///
/// Supports multi-record ClientHello: if the handshake message spans
/// multiple TLS records (ContentType 0x16), their payloads are reassembled
/// before parsing.
///
/// TLS Record structure:
///   [0]    ContentType (0x16 = Handshake)
///   [1..2] Version (0x0301 = TLS 1.0, 0x0303 = TLS 1.2)
///   [3..4] Record length (big-endian u16)
///   [5..]  Handshake message
///
/// Handshake ClientHello:
///   [0]    HandshakeType (0x01 = ClientHello)
///   [1..3] Length (big-endian u24)
///   [4..5] ClientVersion
///   [6..37] Random (32 bytes)
///   [38]   SessionID length
///   ...    SessionID
///   ...    CipherSuites (u16 length + data)
///   ...    Compression methods (u8 length + data)
///   ...    Extensions (u16 total length + extension list)
fn parse_sni(data: &[u8]) -> SniResult {
    let handshake_payload = match reassemble_handshake(data) {
        Ok(p) => p,
        Err(ReassembleError::NeedMoreData) => return SniResult::NeedMoreData,
        Err(ReassembleError::Invalid) => return SniResult::Invalid,
    };

    parse_sni_from_handshake(&handshake_payload)
}

/// Parse SNI from a reassembled handshake payload.
fn parse_sni_from_handshake(handshake: &[u8]) -> SniResult {
    // Handshake header: type(1) + length(3)
    if handshake.len() < 4 {
        return SniResult::Invalid;
    }
    if handshake[0] != 0x01 {
        // Not a ClientHello
        return SniResult::Invalid;
    }

    let hs_len =
        (handshake[1] as usize) << 16 | (handshake[2] as usize) << 8 | (handshake[3] as usize);
    if handshake.len() < 4 + hs_len {
        return SniResult::NeedMoreData;
    }

    let ch = &handshake[4..4 + hs_len];

    // ClientHello body: Version(2) + Random(32) + SessionIDLen(1)
    if ch.len() < 35 {
        return SniResult::Invalid;
    }

    let mut pos: usize = 2 + 32; // skip version + random

    // Session ID
    let session_id_len = ch[pos] as usize;
    pos += 1 + session_id_len;
    if pos + 2 > ch.len() {
        return SniResult::Invalid;
    }

    // Cipher suites
    let cipher_suites_len = u16::from_be_bytes([ch[pos], ch[pos + 1]]) as usize;
    pos += 2 + cipher_suites_len;
    if pos + 1 > ch.len() {
        return SniResult::Invalid;
    }

    // Compression methods
    let compression_len = ch[pos] as usize;
    pos += 1 + compression_len;

    // Extensions (optional — old TLS without extensions is valid)
    if pos >= ch.len() {
        // No extensions
        return SniResult::Ok(String::new());
    }

    if pos + 2 > ch.len() {
        return SniResult::Invalid;
    }

    let extensions_len = u16::from_be_bytes([ch[pos], ch[pos + 1]]) as usize;
    pos += 2;

    if pos + extensions_len > ch.len() {
        return SniResult::Invalid;
    }

    let ext_end = pos + extensions_len;

    // Walk extensions looking for server_name (type 0x0000)
    while pos + 4 <= ext_end {
        let ext_type = u16::from_be_bytes([ch[pos], ch[pos + 1]]);
        let ext_len = u16::from_be_bytes([ch[pos + 2], ch[pos + 3]]) as usize;
        pos += 4;

        if pos + ext_len > ext_end {
            return SniResult::Invalid;
        }

        if ext_type == 0x0000 {
            // Server Name extension
            // server_name_list_length (2) + entries
            if ext_len < 2 {
                return SniResult::Invalid;
            }
            let _list_len = u16::from_be_bytes([ch[pos], ch[pos + 1]]) as usize;
            let mut sni_pos = pos + 2;

            while sni_pos + 3 <= pos + ext_len {
                let name_type = ch[sni_pos];
                let name_len =
                    u16::from_be_bytes([ch[sni_pos + 1], ch[sni_pos + 2]]) as usize;
                sni_pos += 3;

                if sni_pos + name_len > pos + ext_len {
                    return SniResult::Invalid;
                }

                if name_type == 0x00 {
                    // host_name
                    match std::str::from_utf8(&ch[sni_pos..sni_pos + name_len]) {
                        Ok(s) => return SniResult::Ok(s.to_string()),
                        Err(_) => return SniResult::Invalid,
                    }
                }

                sni_pos += name_len;
            }

            // SNI extension found but no host_name entry
            return SniResult::Ok(String::new());
        }

        pos += ext_len;
    }

    // No SNI extension
    SniResult::Ok(String::new())
}

// ---------------------------------------------------------------------------
// CIDR Radix Tree
// ---------------------------------------------------------------------------

/// Node in the binary radix trie (bit-level).
/// Each node represents a single bit position in a 32-bit IPv4 address.
/// Children[0] = left (bit 0), Children[1] = right (bit 1).
struct RadixNode {
    children: [Option<Box<RadixNode>>; 2],
    /// If Some, this node marks the end of an inserted prefix.
    rule_index: Option<u32>,
}

impl RadixNode {
    fn new() -> Self {
        RadixNode {
            children: [None, None],
            rule_index: None,
        }
    }
}

/// Opaque radix trie handle exposed to C callers.
/// Uses a binary trie for O(32) = O(1) longest-prefix-match lookups.
pub struct LuagateRadix {
    root: RadixNode,
}

/// Build a radix tree from a newline-separated CIDR list.
///
/// Format: "192.168.0.0/16,0\n10.0.0.0/8,1\n..."
/// Each line: CIDR,rule_index
///
/// # Safety
/// `cidr_list` must be valid for `cidr_list_len` bytes.
/// `tree_out` must be a valid pointer to a `*mut LuagateRadix`.
#[no_mangle]
pub extern "C" fn luagate_radix_build(
    cidr_list: *const i8,
    cidr_list_len: usize,
    tree_out: *mut *mut LuagateRadix,
) -> i32 {
    if tree_out.is_null() {
        return LUAGATE_INTERNAL_ERROR;
    }

    if cidr_list.is_null() || cidr_list_len == 0 {
        // Empty list — build an empty tree (valid, matches nothing)
        let tree = Box::new(LuagateRadix {
            root: RadixNode::new(),
        });
        unsafe { *tree_out = Box::into_raw(tree); }
        return LUAGATE_OK;
    }

    let bytes = unsafe { std::slice::from_raw_parts(cidr_list as *const u8, cidr_list_len) };
    let input = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return LUAGATE_INVALID_INPUT,
    };

    let mut root = RadixNode::new();

    for line in input.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Parse "CIDR,rule_index"
        let (cidr_str, rule_index) = match line.rsplit_once(',') {
            Some((c, r)) => {
                let idx = match r.trim().parse::<u32>() {
                    Ok(v) => v,
                    Err(_) => return LUAGATE_INVALID_INPUT,
                };
                (c.trim(), idx)
            }
            None => return LUAGATE_INVALID_INPUT,
        };

        // Parse CIDR "a.b.c.d/prefix"
        let (addr_str, prefix_str) = match cidr_str.split_once('/') {
            Some((a, p)) => (a, p),
            None => return LUAGATE_INVALID_INPUT,
        };

        let addr: Ipv4Addr = match addr_str.parse() {
            Ok(a) => a,
            Err(_) => return LUAGATE_INVALID_INPUT,
        };

        let prefix_len: u8 = match prefix_str.parse() {
            Ok(p) if p <= 32 => p,
            _ => return LUAGATE_INVALID_INPUT,
        };

        let network = u32::from(addr);

        // Insert into trie: walk prefix_len bits from MSB
        let mut node = &mut root;
        for bit_pos in 0..prefix_len {
            let bit = ((network >> (31 - bit_pos)) & 1) as usize;
            node = node.children[bit].get_or_insert_with(|| Box::new(RadixNode::new()));
        }
        // Longer prefix wins: always overwrite (last insert at same prefix wins,
        // but typically each CIDR is unique). For overlapping prefixes, the trie
        // naturally provides longest-prefix-match during lookup.
        node.rule_index = Some(rule_index);
    }

    let tree = Box::new(LuagateRadix { root });
    unsafe { *tree_out = Box::into_raw(tree); }
    LUAGATE_OK
}

/// Look up an IP address in the radix tree.
///
/// Returns LUAGATE_OK and sets `matched_rule_index_out` to the rule index
/// of the longest matching prefix, or u32::MAX if no match.
///
/// # Safety
/// `tree` must be a valid pointer returned by `luagate_radix_build`.
/// `ip_str` must be valid for `ip_str_len` bytes.
#[no_mangle]
pub extern "C" fn luagate_radix_lookup(
    tree: *const LuagateRadix,
    ip_str: *const i8,
    ip_str_len: usize,
    matched_rule_index_out: *mut u32,
) -> i32 {
    if tree.is_null() || matched_rule_index_out.is_null() {
        return LUAGATE_INTERNAL_ERROR;
    }

    unsafe { *matched_rule_index_out = u32::MAX; }

    if ip_str.is_null() || ip_str_len == 0 {
        return LUAGATE_INVALID_INPUT;
    }

    let bytes = unsafe { std::slice::from_raw_parts(ip_str as *const u8, ip_str_len) };
    let ip_string = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return LUAGATE_INVALID_INPUT,
    };

    let addr: Ipv4Addr = match ip_string.parse() {
        Ok(a) => a,
        Err(_) => return LUAGATE_INVALID_INPUT,
    };

    let ip_u32 = u32::from(addr);
    let tree_ref = unsafe { &*tree };

    // Walk the trie bit-by-bit (MSB first), tracking the last seen rule_index.
    // This gives longest-prefix-match in O(32) steps.
    let mut best_match: Option<u32> = tree_ref.root.rule_index;
    let mut node = &tree_ref.root;

    for bit_pos in 0..32u8 {
        let bit = ((ip_u32 >> (31 - bit_pos)) & 1) as usize;
        match &node.children[bit] {
            Some(child) => {
                node = child;
                if let Some(idx) = node.rule_index {
                    best_match = Some(idx);
                }
            }
            None => break,
        }
    }

    if let Some(idx) = best_match {
        unsafe { *matched_rule_index_out = idx; }
    }

    LUAGATE_OK
}

/// Free a radix tree previously built by `luagate_radix_build`.
///
/// # Safety
/// `tree` must be a pointer returned by `luagate_radix_build` that has not
/// already been freed.  NULL is a safe no-op.
#[no_mangle]
pub extern "C" fn luagate_radix_free(tree: *mut LuagateRadix) -> i32 {
    if !tree.is_null() {
        unsafe { drop(Box::from_raw(tree)); }
    }
    LUAGATE_OK
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ── detect_protocol tests ────────────────────────────────────────────

    fn detect(data: &[u8]) -> (i32, String) {
        let mut proto_buf = vec![0i8; 16];
        let mut proto_len: usize = 0;

        let rc = luagate_detect_protocol(
            data.as_ptr() as *const i8,
            data.len(),
            proto_buf.as_mut_ptr(),
            16,
            &mut proto_len,
        );

        let proto = if proto_len > 0 {
            let bytes: Vec<u8> = proto_buf[..proto_len].iter().map(|&b| b as u8).collect();
            String::from_utf8_lossy(&bytes).to_string()
        } else {
            String::new()
        };

        (rc, proto)
    }

    #[test]
    fn test_detect_tls() {
        // TLS record: ContentType=0x16, Version=0x0303
        let data = [0x16, 0x03, 0x03, 0x00, 0x05, 0x01, 0x00, 0x00, 0x01, 0x00];
        let (rc, proto) = detect(&data);
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(proto, "tls");
    }

    #[test]
    fn test_detect_tls_need_more_data() {
        // Only ContentType byte
        let data = [0x16];
        let (rc, _) = detect(&data);
        assert_eq!(rc, LUAGATE_NEED_MORE_DATA);
    }

    #[test]
    fn test_detect_tls_malformed() {
        // 0x16 but version not 0x03
        let data = [0x16, 0x04, 0x00];
        let (rc, _) = detect(&data);
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_detect_http_get() {
        let data = b"GET / HTTP/1.1\r\n";
        let (rc, proto) = detect(data);
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(proto, "http");
    }

    #[test]
    fn test_detect_http_post() {
        let data = b"POST /api HTTP/1.1\r\n";
        let (rc, proto) = detect(data);
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(proto, "http");
    }

    #[test]
    fn test_detect_connect_classified_as_raw() {
        // CONNECT is excluded from HTTP methods per spec (MVP does not support CONNECT).
        // CONNECT-prefixed data is classified as "raw".
        let data = b"CONNECT example.com:443 HTTP/1.1\r\n";
        let (rc, proto) = detect(data);
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(proto, "raw");
    }

    #[test]
    fn test_detect_raw() {
        let data = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05];
        let (rc, proto) = detect(&data);
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(proto, "raw");
    }

    #[test]
    fn test_detect_empty() {
        let (rc, _) = detect(&[]);
        assert_eq!(rc, LUAGATE_NEED_MORE_DATA);
    }

    #[test]
    fn test_detect_null_buf() {
        let mut proto_buf = vec![0i8; 16];
        let mut proto_len: usize = 0;
        let rc = luagate_detect_protocol(
            std::ptr::null(),
            0,
            proto_buf.as_mut_ptr(),
            16,
            &mut proto_len,
        );
        assert_eq!(rc, LUAGATE_NEED_MORE_DATA);
    }

    // ── extract_sni tests ────────────────────────────────────────────────

    /// Build a minimal TLS ClientHello with the given SNI hostname.
    fn build_client_hello(sni: &str) -> Vec<u8> {
        // SNI extension
        let sni_bytes = sni.as_bytes();
        // server_name entry: type(1) + name_len(2) + name
        let sni_entry_len = 1 + 2 + sni_bytes.len();
        // server_name_list: list_len(2) + entries
        let sni_ext_data_len = 2 + sni_entry_len;
        // extension: type(2) + len(2) + data
        let ext_len = 4 + sni_ext_data_len;

        // Build ClientHello body
        let mut ch = Vec::new();
        // Version: TLS 1.2
        ch.extend_from_slice(&[0x03, 0x03]);
        // Random: 32 zero bytes
        ch.extend_from_slice(&[0u8; 32]);
        // Session ID length: 0
        ch.push(0);
        // Cipher suites: length 2, one suite
        ch.extend_from_slice(&[0x00, 0x02, 0x00, 0x2f]);
        // Compression methods: length 1, null
        ch.extend_from_slice(&[0x01, 0x00]);
        // Extensions total length
        ch.extend_from_slice(&(ext_len as u16).to_be_bytes());
        // SNI extension type (0x0000)
        ch.extend_from_slice(&[0x00, 0x00]);
        // SNI extension data length
        ch.extend_from_slice(&(sni_ext_data_len as u16).to_be_bytes());
        // Server name list length
        ch.extend_from_slice(&(sni_entry_len as u16).to_be_bytes());
        // Name type: host_name (0)
        ch.push(0x00);
        // Name length
        ch.extend_from_slice(&(sni_bytes.len() as u16).to_be_bytes());
        // Name
        ch.extend_from_slice(sni_bytes);

        // Wrap in Handshake
        let mut hs = Vec::new();
        hs.push(0x01); // ClientHello
        let ch_len = ch.len();
        hs.push((ch_len >> 16) as u8);
        hs.push((ch_len >> 8) as u8);
        hs.push(ch_len as u8);
        hs.extend_from_slice(&ch);

        // Wrap in TLS record
        let mut record = Vec::new();
        record.push(0x16); // Handshake
        record.extend_from_slice(&[0x03, 0x01]); // Version TLS 1.0 (record layer)
        let hs_len = hs.len();
        record.extend_from_slice(&(hs_len as u16).to_be_bytes());
        record.extend_from_slice(&hs);

        record
    }

    #[test]
    fn test_extract_sni_basic() {
        let data = build_client_hello("api.example.com");
        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;

        let rc = luagate_extract_sni(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );

        assert_eq!(rc, LUAGATE_OK);
        assert!(out_len > 0);
        let sni_bytes: Vec<u8> = out[..out_len].iter().map(|&b| b as u8).collect();
        assert_eq!(String::from_utf8_lossy(&sni_bytes), "api.example.com");
    }

    #[test]
    fn test_extract_sni_no_sni_extension() {
        // Build a ClientHello without SNI extension
        let mut ch = Vec::new();
        ch.extend_from_slice(&[0x03, 0x03]); // version
        ch.extend_from_slice(&[0u8; 32]); // random
        ch.push(0); // session_id_len
        ch.extend_from_slice(&[0x00, 0x02, 0x00, 0x2f]); // cipher suites
        ch.extend_from_slice(&[0x01, 0x00]); // compression

        // No extensions at all

        let mut hs = Vec::new();
        hs.push(0x01);
        let ch_len = ch.len();
        hs.push((ch_len >> 16) as u8);
        hs.push((ch_len >> 8) as u8);
        hs.push(ch_len as u8);
        hs.extend_from_slice(&ch);

        let mut record = Vec::new();
        record.push(0x16);
        record.extend_from_slice(&[0x03, 0x01]);
        let hs_len = hs.len();
        record.extend_from_slice(&(hs_len as u16).to_be_bytes());
        record.extend_from_slice(&hs);

        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;
        let rc = luagate_extract_sni(
            record.as_ptr() as *const i8,
            record.len(),
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );

        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(out_len, 0); // No SNI
    }

    #[test]
    fn test_extract_sni_need_more_data() {
        // Only TLS record header, no handshake data
        let data: [u8; 5] = [0x16, 0x03, 0x01, 0x00, 0x50]; // claims 80 bytes but we only have 5
        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;
        let rc = luagate_extract_sni(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );
        assert_eq!(rc, LUAGATE_NEED_MORE_DATA);
    }

    #[test]
    fn test_extract_sni_invalid_not_handshake() {
        // Valid TLS record but not handshake (type 0x17 = Application Data)
        let mut data = vec![0x17, 0x03, 0x03, 0x00, 0x04];
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]);
        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;
        let rc = luagate_extract_sni(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );
        // Not a handshake record
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_extract_sni_null_buf() {
        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;
        let rc = luagate_extract_sni(
            std::ptr::null(),
            0,
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );
        assert_eq!(rc, LUAGATE_NEED_MORE_DATA);
    }

    #[test]
    fn test_extract_sni_buffer_too_small() {
        let data = build_client_hello("api.example.com");
        let mut out = vec![0i8; 2]; // too small for "api.example.com"
        let mut out_len: usize = 0;
        let rc = luagate_extract_sni(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            2,
            &mut out_len,
        );
        assert_eq!(rc, LUAGATE_BUFFER_TOO_SMALL);
    }

    // ── radix tree tests ─────────────────────────────────────────────────

    #[test]
    fn test_radix_build_and_lookup() {
        let cidr_list = "192.168.0.0/16,0\n10.0.0.0/8,1\n";
        let mut tree: *mut LuagateRadix = std::ptr::null_mut();

        let rc = luagate_radix_build(
            cidr_list.as_ptr() as *const i8,
            cidr_list.len(),
            &mut tree,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert!(!tree.is_null());

        // Match 192.168.1.1 → rule 0
        let ip = "192.168.1.1";
        let mut rule_idx: u32 = u32::MAX;
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, 0);

        // Match 10.1.2.3 → rule 1
        let ip = "10.1.2.3";
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, 1);

        // No match 8.8.8.8 → UINT32_MAX
        let ip = "8.8.8.8";
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, u32::MAX);

        // Free
        let rc = luagate_radix_free(tree);
        assert_eq!(rc, LUAGATE_OK);
    }

    #[test]
    fn test_radix_longest_prefix_match() {
        // More specific CIDR should match first
        let cidr_list = "10.0.0.0/8,0\n10.1.0.0/16,1\n10.1.2.0/24,2\n";
        let mut tree: *mut LuagateRadix = std::ptr::null_mut();

        let rc = luagate_radix_build(
            cidr_list.as_ptr() as *const i8,
            cidr_list.len(),
            &mut tree,
        );
        assert_eq!(rc, LUAGATE_OK);

        let ip = "10.1.2.3";
        let mut rule_idx: u32 = u32::MAX;
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, 2); // /24 is longest match

        let ip = "10.1.3.1";
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, 1); // /16 match

        let ip = "10.2.0.1";
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, 0); // /8 match

        luagate_radix_free(tree);
    }

    #[test]
    fn test_radix_empty_list() {
        let mut tree: *mut LuagateRadix = std::ptr::null_mut();
        let rc = luagate_radix_build(
            std::ptr::null(),
            0,
            &mut tree,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert!(!tree.is_null());

        let ip = "10.0.0.1";
        let mut rule_idx: u32 = 0;
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_OK);
        assert_eq!(rule_idx, u32::MAX);

        luagate_radix_free(tree);
    }

    #[test]
    fn test_radix_invalid_cidr() {
        let cidr_list = "not-a-cidr,0\n";
        let mut tree: *mut LuagateRadix = std::ptr::null_mut();
        let rc = luagate_radix_build(
            cidr_list.as_ptr() as *const i8,
            cidr_list.len(),
            &mut tree,
        );
        assert_eq!(rc, LUAGATE_INVALID_INPUT);
    }

    #[test]
    fn test_radix_invalid_ip_lookup() {
        let cidr_list = "10.0.0.0/8,0\n";
        let mut tree: *mut LuagateRadix = std::ptr::null_mut();
        let rc = luagate_radix_build(
            cidr_list.as_ptr() as *const i8,
            cidr_list.len(),
            &mut tree,
        );
        assert_eq!(rc, LUAGATE_OK);

        let ip = "not-an-ip";
        let mut rule_idx: u32 = 0;
        let rc = luagate_radix_lookup(
            tree,
            ip.as_ptr() as *const i8,
            ip.len(),
            &mut rule_idx,
        );
        assert_eq!(rc, LUAGATE_INVALID_INPUT);

        luagate_radix_free(tree);
    }

    #[test]
    fn test_radix_free_null() {
        let rc = luagate_radix_free(std::ptr::null_mut());
        assert_eq!(rc, LUAGATE_OK);
    }

    #[test]
    fn test_radix_null_tree_out() {
        let cidr_list = "10.0.0.0/8,0\n";
        let rc = luagate_radix_build(
            cidr_list.as_ptr() as *const i8,
            cidr_list.len(),
            std::ptr::null_mut(),
        );
        assert_eq!(rc, LUAGATE_INTERNAL_ERROR);
    }

    /// Build a fragmented ClientHello split across two TLS records.
    /// The first record contains the handshake header + first `split_at` bytes
    /// of the ClientHello body; the second record contains the rest.
    fn build_fragmented_client_hello(sni: &str, split_at: usize) -> Vec<u8> {
        // First build a single-record ClientHello, then split the handshake.
        let single = build_client_hello(sni);

        // single = [TLS record header (5)] [handshake data]
        let handshake_data = &single[5..];

        // Split handshake into two parts
        let actual_split = split_at.min(handshake_data.len().saturating_sub(1)).max(1);
        let part1 = &handshake_data[..actual_split];
        let part2 = &handshake_data[actual_split..];

        let mut result = Vec::new();

        // First TLS record
        result.push(0x16); // Handshake
        result.extend_from_slice(&[0x03, 0x01]); // TLS 1.0 record layer
        result.extend_from_slice(&(part1.len() as u16).to_be_bytes());
        result.extend_from_slice(part1);

        // Second TLS record
        result.push(0x16); // Handshake
        result.extend_from_slice(&[0x03, 0x01]); // TLS 1.0 record layer
        result.extend_from_slice(&(part2.len() as u16).to_be_bytes());
        result.extend_from_slice(part2);

        result
    }

    #[test]
    fn test_extract_sni_fragmented_two_records() {
        // Split the handshake at byte 10 (within the handshake header area)
        let data = build_fragmented_client_hello("fragmented.example.com", 10);
        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;

        let rc = luagate_extract_sni(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );

        assert_eq!(rc, LUAGATE_OK);
        assert!(out_len > 0);
        let sni_bytes: Vec<u8> = out[..out_len].iter().map(|&b| b as u8).collect();
        assert_eq!(
            String::from_utf8_lossy(&sni_bytes),
            "fragmented.example.com"
        );
    }

    #[test]
    fn test_extract_sni_fragmented_split_in_extensions() {
        // Split deep into the handshake (after session ID, into extensions area)
        let data = build_fragmented_client_hello("deep-split.example.com", 50);
        let mut out = vec![0i8; 256];
        let mut out_len: usize = 0;

        let rc = luagate_extract_sni(
            data.as_ptr() as *const i8,
            data.len(),
            out.as_mut_ptr(),
            256,
            &mut out_len,
        );

        assert_eq!(rc, LUAGATE_OK);
        assert!(out_len > 0);
        let sni_bytes: Vec<u8> = out[..out_len].iter().map(|&b| b as u8).collect();
        assert_eq!(
            String::from_utf8_lossy(&sni_bytes),
            "deep-split.example.com"
        );
    }

    #[test]
    fn test_detect_protocol_buffer_too_small() {
        let data = b"GET / HTTP/1.1\r\n";
        let mut proto_buf = vec![0i8; 2]; // too small for "http"
        let mut proto_len: usize = 0;
        let rc = luagate_detect_protocol(
            data.as_ptr() as *const i8,
            data.len(),
            proto_buf.as_mut_ptr(),
            2,
            &mut proto_len,
        );
        assert_eq!(rc, LUAGATE_BUFFER_TOO_SMALL);
    }
}
