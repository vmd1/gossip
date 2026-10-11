//! Pairing helpers: the comparison code both screens show, and constant-time token checks.

use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

/// A six-digit code ("123 456") derived from both Noise static keys so the user can see the two devices agree.
/// Order-independent: `SHA-256("gossip-pairing-code-v1" || lo || hi)`, first four bytes mod 10^6.
pub fn code(a: &[u8], b: &[u8]) -> String {
    let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
    let mut h = Sha256::new();
    h.update(b"gossip-pairing-code-v1");
    h.update(lo);
    h.update(hi);
    let d = h.finalize();
    let value = u32::from_be_bytes([d[0], d[1], d[2], d[3]]) % 1_000_000;
    let s = format!("{value:06}");
    format!("{} {}", &s[..3], &s[3..])
}

/// Whether what the user typed is the displayed code; separators and spaces are ignored.
pub fn entry_matches(entry: &str, expected: &str) -> bool {
    let digits = |s: &str| s.chars().filter(|c| c.is_ascii_digit()).collect::<String>();
    let (typed, want) = (digits(entry), digits(expected));
    want.len() == 6 && typed == want
}

/// Constant-time token comparison; `None` on either side never matches.
pub fn token_matches(armed: Option<&str>, presented: Option<&str>) -> bool {
    match (armed, presented) {
        (Some(a), Some(p)) => a.len() == p.len() && bool::from(a.as_bytes().ct_eq(p.as_bytes())),
        _ => false,
    }
}
