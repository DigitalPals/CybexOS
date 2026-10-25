//! Username and computer-name input, filtered as it is typed.
//!
//! The installer worker accepts `[a-z][a-z0-9-]{0,30}` for both names. The
//! screen never lets anything else in: uppercase becomes lowercase, accents
//! fold to their base letter, and every other character is refused with a
//! one-line reason. The worker validates again; both use the same rule.

use unicode_normalization::UnicodeNormalization;

pub const MAX_LEN: usize = 31;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Filtered {
    pub text: String,
    /// Caret position in bytes (equal to characters: the result is ASCII).
    pub caret: usize,
    /// Why the input changed, if it did; empty otherwise.
    pub note: String,
}

fn fold(ch: char) -> Option<char> {
    let lower: String = ch.to_lowercase().collect();
    let base: String = lower.nfd().filter(|c| !is_combining(*c)).collect();
    let mut chars = base.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => Some(c),
        _ => None,
    }
}

fn is_combining(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036f | 0x1ab0..=0x1aff | 0x1dc0..=0x1dff | 0x20d0..=0x20ff | 0xfe20..=0xfe2f)
}

fn filter_text(raw: &str) -> (String, String) {
    let mut out = String::new();
    let mut note = String::new();
    let mut hard = false;
    for ch in raw.chars() {
        let folded = fold(ch);
        let c = folded.unwrap_or(ch);
        if !hard && c.is_ascii_lowercase() && c != ch {
            note = if ch.is_uppercase() && ch.to_lowercase().eq(std::iter::once(c)) {
                format!("“{ch}” became “{c}”: names are lowercase")
            } else {
                format!("“{ch}” became “{c}”")
            };
        }
        if !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
            note = if ch == ' ' {
                "Spaces aren't allowed. Use a hyphen.".to_string()
            } else {
                format!("“{ch}” isn't allowed. Use letters, digits and hyphens.")
            };
            hard = true;
            continue;
        }
        if out.is_empty() && !c.is_ascii_lowercase() {
            note = "Start with a letter.".to_string();
            hard = true;
            continue;
        }
        if out.len() >= MAX_LEN {
            note = format!("{MAX_LEN} characters at most.");
            break;
        }
        out.push(c);
    }
    (out, note)
}

/// Filter `raw` and keep the caret where the user was typing.
pub fn filter(raw: &str, caret_bytes: usize) -> Filtered {
    let (text, note) = filter_text(raw);
    let mut cut = caret_bytes.min(raw.len());
    while cut > 0 && !raw.is_char_boundary(cut) {
        cut -= 1;
    }
    let caret = filter_text(&raw[..cut]).0.len().min(text.len());
    Filtered { text, caret, note }
}

pub fn is_valid(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= MAX_LEN
        && bytes[0].is_ascii_lowercase()
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

/// A username suggestion from a typed name: the first word, folded.
pub fn suggest(full_name: &str) -> String {
    let words: Vec<String> = full_name
        .split_whitespace()
        .map(|w| filter_text(&w.to_lowercase()).0)
        .filter(|w| !w.is_empty())
        .collect();
    match words.first() {
        None => String::new(),
        Some(first) if first.len() >= 2 => first.clone(),
        Some(_) => words.concat().chars().take(MAX_LEN).collect(),
    }
}

/// A personal greeting, falling back to the login name when no name was entered.
pub fn given_name(full_name: &str, username: &str) -> String {
    let name = full_name.split_whitespace().next().unwrap_or(username);
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

pub fn hostname_for(username: &str) -> String {
    const SUFFIX: &str = "-cybexos";
    if username.is_empty() {
        "cybexos".to_string()
    } else {
        format!("{}{SUFFIX}", &username[..username.len().min(MAX_LEN - SUFFIX.len())])
    }
}

/// The same restrictions the worker applies to a GECOS/Nix description.
pub fn full_name_problem(name: &str) -> Option<&'static str> {
    if name.chars().count() > 64 || name.chars().any(|c| (c as u32) < 32 || c as u32 == 127 || ":,\\\"$`".contains(c)) {
        Some("Your name may not contain : , \\ \" $ ` or control characters.")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Shared vectors: the worker's validate_field accepts exactly the valid ones.
    const VALID: &[&str] = &["a", "ada", "dev-ops2", "x1", "a-", "abcdefghijklmnopqrstuvwxyz01234"];
    const INVALID: &[&str] = &["", "Ada", "1ada", "-ada", "ada lovelace", "ada.l", "é", "abcdefghijklmnopqrstuvwxyz012345"];

    #[test]
    fn validity_matches_the_worker_pattern() {
        for name in VALID {
            assert!(is_valid(name), "{name}");
        }
        for name in INVALID {
            assert!(!is_valid(name), "{name}");
        }
    }

    #[test]
    fn uppercase_becomes_lowercase_with_a_note() {
        let f = filter("John", 4);
        assert_eq!(f.text, "john");
        assert_eq!(f.caret, 4);
        assert!(f.note.contains("“J” became “j”"), "{}", f.note);
    }

    #[test]
    fn refused_characters_win_over_case_notes() {
        let f = filter("John.Doe", 8);
        assert_eq!(f.text, "johndoe");
        assert!(f.note.contains("“.” isn't allowed"), "{}", f.note);
    }

    #[test]
    fn accents_fold_and_leading_digits_or_hyphens_are_refused() {
        assert_eq!(filter("Élodie", 7).text, "elodie");
        let f = filter("9lives", 6);
        assert_eq!(f.text, "lives");
        assert_eq!(f.note, "Start with a letter.");
        assert_eq!(filter("-x", 2).text, "x");
        assert_eq!(filter("ada lovelace", 12).note, "Spaces aren't allowed. Use a hyphen.");
    }

    #[test]
    fn length_is_capped_and_caret_tracks_the_typing_position() {
        let f = filter(&"a".repeat(40), 40);
        assert_eq!(f.text.len(), MAX_LEN);
        assert_eq!(f.note, "31 characters at most.");
        // Typing an uppercase letter in the middle keeps the caret after it.
        let f = filter("abXcd", 3);
        assert_eq!((f.text.as_str(), f.caret), ("abxcd", 3));
        // A refused character before the caret moves the caret back one.
        let f = filter("ab.cd", 3);
        assert_eq!((f.text.as_str(), f.caret), ("abcd", 2));
    }

    #[test]
    fn suggestions_hostnames_and_full_names() {
        assert_eq!(suggest("José García"), "jose");
        assert_eq!(suggest("J. Doe"), "jdoe");
        assert_eq!(suggest("  "), "");
        assert_eq!(hostname_for("ada"), "ada-cybexos");
        assert_eq!(hostname_for(""), "cybexos");
        assert_eq!(hostname_for(&"a".repeat(31)).len(), 31);
        assert!(full_name_problem("Ada Lovelace").is_none());
        assert!(full_name_problem("O'Brien-Smith").is_none());
        assert!(full_name_problem("Ada: admin").is_some());
        assert!(full_name_problem("${x}").is_some());
    }
}
