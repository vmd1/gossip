//! Minimal UUID text handling (no dependency): validation and formatting of the canonical 8-4-4-4-12 form.

/// Whether `s` is a UUID in canonical hyphenated form. Case-insensitive, any version (the apps accept whatever
/// `UUID(uuidString:)` / `UUID.fromString` accept for this shape).
pub fn is_valid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

pub fn format(bytes: &[u8; 16]) -> String {
    let h: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}
