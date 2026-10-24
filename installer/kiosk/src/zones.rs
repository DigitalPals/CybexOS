//! Time zones: search, live local time and the next clock change.
//!
//! The list arrives from the daemon, built from the medium's own `zone.tab`
//! (one familiar entry per country) with tzdata's backward links as search
//! aliases. Times are computed from the medium's TZif files, the same tzdata
//! revision the installed system receives. A selection is always a zone ID,
//! never an index into a filtered list.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;

use tz::TimeZone;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone)]
pub struct Zone {
    pub id: String,
    pub country_code: String,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub comment: String,
    pub city: String,
    pub country: String,
    pub aliases: Vec<String>,
    /// UTC and the fixed Etc/GMT offsets: no coordinates, no daylight saving.
    pub fixed: bool,
    keys: Keys,
}

#[derive(Debug, Clone, Default)]
struct Keys {
    city: String,
    country: String,
    comment: String,
    id: String,
    aliases: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub index: usize,
    /// The retired name that matched, e.g. "Europe/Kiev" for Kyiv.
    pub alias: Option<String>,
}

pub fn normalize(text: &str) -> String {
    let folded: String = text
        .to_lowercase()
        .nfd()
        .filter(|c| !matches!(*c as u32, 0x0300..=0x036f))
        .map(|c| if c == '_' || c == '/' { ' ' } else { c })
        .collect();
    folded.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub struct ZoneDb {
    pub zones: Vec<Zone>,
    pub tzdata: String,
    by_id: HashMap<String, usize>,
    aliases: HashMap<String, String>,
    cache: RefCell<HashMap<String, Option<TimeZone>>>,
    root: PathBuf,
}

impl ZoneDb {
    /// `zones` rows are `[id, countryCode, lat, lon, comment]`.
    pub fn new(
        rows: &[(String, String, f64, f64, String)],
        countries: &HashMap<String, String>,
        aliases: &HashMap<String, String>,
        tzdata: &str,
    ) -> Self {
        let mut zones: Vec<Zone> = rows
            .iter()
            .filter(|row| row.0 != "UTC")
            .map(|(id, cc, lat, lon, comment)| {
                let city = id.rsplit('/').next().unwrap_or(id).replace('_', " ");
                Zone {
                    id: id.clone(),
                    country_code: cc.clone(),
                    lat: Some(*lat),
                    lon: Some(*lon),
                    comment: comment.clone(),
                    city,
                    country: countries.get(cc).cloned().unwrap_or_else(|| cc.clone()),
                    aliases: Vec::new(),
                    fixed: false,
                    keys: Keys::default(),
                }
            })
            .collect();
        zones.push(Zone {
            id: "UTC".into(),
            country_code: String::new(),
            lat: None,
            lon: None,
            comment: String::new(),
            city: "UTC".into(),
            country: "Coordinated Universal Time".into(),
            aliases: Vec::new(),
            fixed: true,
            keys: Keys::default(),
        });
        // tzdata's POSIX-style names invert the sign: Etc/GMT+5 is UTC−05:00.
        for hours in -14i32..=12 {
            if hours == 0 {
                continue;
            }
            let id = format!("Etc/GMT{}{}", if hours > 0 { '+' } else { '-' }, hours.abs());
            let real = -hours;
            let label = format!("UTC{}{:02}:00", if real > 0 { '+' } else { '−' }, real.abs());
            zones.push(Zone {
                id: id.clone(),
                country_code: String::new(),
                lat: None,
                lon: None,
                comment: "fixed offset, no daylight saving".into(),
                city: label,
                country: id,
                aliases: Vec::new(),
                fixed: true,
                keys: Keys::default(),
            });
        }
        let by_id: HashMap<String, usize> = zones.iter().enumerate().map(|(i, z)| (z.id.clone(), i)).collect();
        let mut sorted_aliases: Vec<(&String, &String)> = aliases.iter().collect();
        sorted_aliases.sort();
        for (link, target) in sorted_aliases {
            if let Some(&index) = by_id.get(target) {
                zones[index].aliases.push(link.clone());
            }
        }
        for zone in &mut zones {
            zone.keys = Keys {
                city: normalize(&zone.city),
                country: normalize(&zone.country),
                comment: normalize(&zone.comment),
                id: normalize(&zone.id),
                aliases: zone.aliases.iter().map(|a| normalize(a.rsplit('/').next().unwrap_or(a))).collect(),
            };
            if zone.fixed && zone.id != "UTC" {
                let real: i32 = -zone.id[7..].parse::<i32>().unwrap_or(0);
                let sign = if real >= 0 { '+' } else { '-' };
                zone.keys.aliases = vec![
                    format!("utc{sign}{}", real.abs()),
                    format!("utc{sign}{:02}:00", real.abs()),
                    format!("gmt{sign}{}", real.abs()),
                ];
            }
        }
        let root = std::env::var_os("TZDIR")
            .map(PathBuf::from)
            .filter(|p| p.join("UTC").exists())
            .or_else(|| ["/etc/zoneinfo", "/usr/share/zoneinfo"].iter().map(PathBuf::from).find(|p| p.join("UTC").exists()))
            .unwrap_or_else(|| PathBuf::from("/etc/zoneinfo"));
        ZoneDb {
            zones,
            tzdata: tzdata.to_string(),
            by_id,
            aliases: aliases.clone(),
            cache: RefCell::new(HashMap::new()),
            root,
        }
    }

    pub fn get(&self, id: &str) -> Option<&Zone> {
        self.by_id.get(id).map(|&i| &self.zones[i])
    }

    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.by_id.get(id).copied()
    }

    /// A known zone ID, or the zone a retired name now points to.
    pub fn canonical(&self, id: &str) -> Option<String> {
        if self.by_id.contains_key(id) {
            Some(id.to_string())
        } else {
            self.aliases.get(id).filter(|t| self.by_id.contains_key(*t)).cloned()
        }
    }

    pub fn search(&self, query: &str, include_fixed: bool, selected: &str, now: i64) -> Vec<Hit> {
        let q = normalize(&query.replace('−', "-"));
        let visible = |z: &Zone| !z.fixed || z.id == "UTC" || include_fixed;
        if q.is_empty() {
            let selected_zone = self.get(selected);
            let country = selected_zone.map(|z| z.country_code.clone()).unwrap_or_default();
            let mut first: Vec<usize> = Vec::new();
            if let Some(i) = self.index_of(selected) {
                first.push(i);
            }
            if !country.is_empty() {
                first.extend(
                    self.zones
                        .iter()
                        .enumerate()
                        .filter(|(i, z)| z.country_code == country && Some(*i) != self.index_of(selected))
                        .map(|(i, _)| i),
                );
            }
            let mut rest: Vec<usize> =
                (0..self.zones.len()).filter(|i| !first.contains(i) && visible(&self.zones[*i])).collect();
            rest.sort_by(|a, b| self.zones[*a].city.cmp(&self.zones[*b].city));
            return first.into_iter().chain(rest).map(|index| Hit { index, alias: None }).collect();
        }
        let offset_query: Option<String> = {
            let compact = q.replace(' ', "").replace("gmt", "utc");
            if compact.starts_with("utc") && compact.len() > 3 && (compact.as_bytes()[3] == b'+' || compact.as_bytes()[3] == b'-') {
                Some(compact)
            } else {
                None
            }
        };
        let mut hits: Vec<(u32, usize, Option<String>)> = Vec::new();
        for (index, zone) in self.zones.iter().enumerate() {
            if !visible(zone) {
                continue;
            }
            let k = &zone.keys;
            let word_start = |s: &str| s.split(' ').any(|w| w.starts_with(&q));
            let mut alias = None;
            let score = if k.city == q || k.country == q {
                110
            } else if k.city.starts_with(&q) {
                100
            } else if k.country.starts_with(&q) {
                85
            } else if let Some(pos) = k.aliases.iter().position(|a| a.starts_with(&q)) {
                alias = zone.aliases.get(pos).cloned();
                75
            } else if word_start(&k.city) || word_start(&k.country) || word_start(&k.comment) {
                60
            } else if let Some(offset) = offset_query.as_ref().filter(|_| !zone.fixed || zone.id == "UTC") {
                if self.short_offset(&zone.id, now).to_lowercase().replace('−', "-") == *offset {
                    50
                } else {
                    0
                }
            } else if k.id.contains(&q) || k.comment.contains(&q) || k.city.contains(&q) {
                30
            } else {
                0
            };
            if score > 0 {
                hits.push((score, index, alias));
            }
        }
        hits.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| self.zones[a.1].city.cmp(&self.zones[b.1].city)));
        hits.into_iter().take(80).map(|(_, index, alias)| Hit { index, alias }).collect()
    }

    /// Nearest zone with coordinates (for clicks on the map).
    pub fn nearest(&self, lat: f64, lon: f64) -> Option<usize> {
        let scale = lat.to_radians().cos();
        self.zones
            .iter()
            .enumerate()
            .filter_map(|(i, z)| {
                let (zl, zo) = (z.lat?, z.lon?);
                let mut dx = (zo - lon).abs();
                if dx > 180.0 {
                    dx = 360.0 - dx;
                }
                let d = (dx * scale).powi(2) + (zl - lat).powi(2);
                Some((i, d))
            })
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| i)
    }

    fn with_zone<T>(&self, id: &str, f: impl FnOnce(&TimeZone) -> T) -> Option<T> {
        let mut cache = self.cache.borrow_mut();
        let entry = cache.entry(id.to_string()).or_insert_with(|| {
            if id.contains("..") || id.starts_with('/') {
                return None;
            }
            std::fs::read(self.root.join(id)).ok().and_then(|bytes| TimeZone::from_tz_data(&bytes).ok())
        });
        entry.as_ref().map(f)
    }

    /// UTC offset in seconds at `now` (Unix seconds).
    pub fn offset(&self, id: &str, now: i64) -> Option<i32> {
        self.with_zone(id, |tz| tz.find_local_time_type(now).ok().map(|t| t.ut_offset())).flatten()
    }

    pub fn local_seconds(&self, id: &str, now: i64) -> Option<i64> {
        self.offset(id, now).map(|offset| now + offset as i64)
    }

    pub fn clock(&self, id: &str, now: i64, seconds: bool) -> String {
        match self.local_seconds(id, now) {
            Some(local) => {
                let day = local.rem_euclid(86_400);
                if seconds {
                    format!("{:02}:{:02}:{:02}", day / 3600, day % 3600 / 60, day % 60)
                } else {
                    format!("{:02}:{:02}", day / 3600, day % 3600 / 60)
                }
            }
            None => "––:––".into(),
        }
    }

    pub fn long_offset(&self, id: &str, now: i64) -> String {
        match self.offset(id, now) {
            Some(offset) => {
                let sign = if offset < 0 { '−' } else { '+' };
                let minutes = offset.abs() / 60;
                format!("UTC{sign}{:02}:{:02}", minutes / 60, minutes % 60)
            }
            None => String::new(),
        }
    }

    pub fn short_offset(&self, id: &str, now: i64) -> String {
        match self.offset(id, now) {
            Some(offset) => {
                let sign = if offset < 0 { '−' } else { '+' };
                let minutes = offset.abs() / 60;
                if minutes % 60 == 0 {
                    format!("UTC{sign}{}", minutes / 60)
                } else {
                    format!("UTC{sign}{}:{:02}", minutes / 60, minutes % 60)
                }
            }
            None => String::new(),
        }
    }

    /// "Clocks go back 1 hour on Sun 25 Oct at 03:00", within the next year.
    pub fn next_change(&self, id: &str, now: i64) -> Option<String> {
        let start = self.offset(id, now)?;
        let mut lo = now;
        let mut hi = None;
        for day in 1..=400i64 {
            let t = now + day * 86_400;
            if self.offset(id, t)? != start {
                hi = Some(t);
                lo = t - 86_400;
                break;
            }
        }
        let mut hi = hi?;
        while hi - lo > 60 {
            let mid = lo + (hi - lo) / 2;
            if self.offset(id, mid)? == start {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        let minute = hi - hi.rem_euclid(60);
        if minute > lo && self.offset(id, minute)? != start {
            hi = minute;
        }
        let end = self.offset(id, hi)?;
        let diff = end - start;
        let wall = hi + start as i64;
        let (y, m, d) = civil_from_days(wall.div_euclid(86_400));
        let weekday = WEEKDAYS[((wall.div_euclid(86_400) + 4).rem_euclid(7)) as usize];
        let _ = y;
        let time = wall.rem_euclid(86_400);
        let amount = match diff.abs() {
            3600 => "1 hour".to_string(),
            seconds if seconds % 3600 == 0 => format!("{} hours", seconds / 3600),
            seconds => format!("{} minutes", seconds / 60),
        };
        Some(format!(
            "Clocks go {} {amount} on {weekday} {d} {} at {:02}:{:02}",
            if diff < 0 { "back" } else { "forward" },
            MONTHS[(m - 1) as usize],
            time / 3600,
            time % 3600 / 60
        ))
    }
}

const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// Howard Hinnant's days-to-civil conversion.
pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn sample() -> ZoneDb {
        let rows = vec![
            ("Europe/Amsterdam".into(), "NL".into(), 52.37, 4.9, String::new()),
            ("Europe/Brussels".into(), "BE".into(), 50.83, 4.33, String::new()),
            ("Europe/Kyiv".into(), "UA".into(), 50.43, 30.52, "most of Ukraine".into()),
            ("Asia/Kolkata".into(), "IN".into(), 22.53, 88.37, String::new()),
            ("America/Indiana/Indianapolis".into(), "US".into(), 39.77, -86.16, "Eastern - IN (most areas)".into()),
            ("America/New_York".into(), "US".into(), 40.71, -74.01, "Eastern (most areas)".into()),
            ("Asia/Tokyo".into(), "JP".into(), 35.65, 139.74, String::new()),
            ("Australia/Lord_Howe".into(), "AU".into(), -31.55, 159.08, "Lord Howe Island".into()),
        ];
        let countries: HashMap<String, String> = [
            ("NL", "Netherlands"), ("BE", "Belgium"), ("UA", "Ukraine"), ("IN", "India"),
            ("US", "United States"), ("JP", "Japan"), ("AU", "Australia"),
        ]
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect();
        let aliases: HashMap<String, String> = [("Europe/Kiev", "Europe/Kyiv"), ("Asia/Calcutta", "Asia/Kolkata")]
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect();
        ZoneDb::new(&rows, &countries, &aliases, "test")
    }

    fn ids(db: &ZoneDb, query: &str, fixed: bool) -> Vec<String> {
        db.search(query, fixed, "Europe/Amsterdam", 1_792_800_000).into_iter().map(|h| db.zones[h.index].id.clone()).collect()
    }

    #[test]
    fn search_by_country_city_alias_comment_and_exact_country() {
        let db = sample();
        assert_eq!(ids(&db, "nether", false)[0], "Europe/Amsterdam");
        assert_eq!(ids(&db, "new york", false), vec!["America/New_York"]);
        let kiev = db.search("kiev", false, "UTC", 0);
        assert_eq!(db.zones[kiev[0].index].id, "Europe/Kyiv");
        assert_eq!(kiev[0].alias.as_deref(), Some("Europe/Kiev"));
        assert_eq!(ids(&db, "calcutta", false)[0], "Asia/Kolkata");
        assert_eq!(ids(&db, "most of ukr", false), vec!["Europe/Kyiv"]);
        // The country itself outranks a city that merely starts with it.
        assert_eq!(ids(&db, "india", false)[0], "Asia/Kolkata");
    }

    #[test]
    fn fixed_offsets_are_opt_in_with_correct_signs() {
        let db = sample();
        assert!(!ids(&db, "utc-5", false).contains(&"Etc/GMT+5".to_string()));
        assert_eq!(ids(&db, "utc-5", true)[0], "Etc/GMT+5");
        assert_eq!(db.get("Etc/GMT+5").unwrap().city, "UTC−05:00");
        assert_eq!(db.get("Etc/GMT-14").unwrap().city, "UTC+14:00");
    }

    #[test]
    fn empty_query_starts_with_the_selection_and_its_country() {
        let db = sample();
        let hits = db.search("", false, "America/New_York", 0);
        assert_eq!(db.zones[hits[0].index].id, "America/New_York");
        assert_eq!(db.zones[hits[1].index].id, "America/Indiana/Indianapolis");
        assert!(hits.iter().all(|h| !db.zones[h.index].fixed || db.zones[h.index].id == "UTC"));
    }

    #[test]
    fn canonical_names_and_nearest_zone() {
        let db = sample();
        assert_eq!(db.canonical("Asia/Calcutta").as_deref(), Some("Asia/Kolkata"));
        assert_eq!(db.canonical("Etc/GMT+5").as_deref(), Some("Etc/GMT+5"));
        assert_eq!(db.canonical("Mars/Olympus"), None);
        assert_eq!(db.zones[db.nearest(52.0, 5.0).unwrap()].id, "Europe/Amsterdam");
        assert_eq!(db.zones[db.nearest(36.0, 140.0).unwrap()].id, "Asia/Tokyo");
    }

    #[test]
    fn times_offsets_and_the_next_clock_change_from_tzif() {
        let db = sample();
        if db.offset("Europe/Amsterdam", 0).is_none() {
            eprintln!("no zoneinfo on this host; skipping TZif checks");
            return;
        }
        // 2026-10-23 19:00:00 UTC: Amsterdam is on summer time until 25 Oct.
        let now = 1_792_782_000;
        assert_eq!(db.long_offset("Europe/Amsterdam", now), "UTC+02:00");
        assert_eq!(db.short_offset("Asia/Kolkata", now), "UTC+5:30");
        assert_eq!(db.long_offset("Etc/GMT+5", now), "UTC−05:00");
        assert_eq!(db.clock("UTC", now, true), "19:00:00");
        assert_eq!(db.clock("Europe/Amsterdam", now, false), "21:00");
        assert_eq!(
            db.next_change("Europe/Amsterdam", now).as_deref(),
            Some("Clocks go back 1 hour on Sun 25 Oct at 03:00")
        );
        assert_eq!(db.next_change("Asia/Tokyo", now), None);
        assert_eq!(
            db.next_change("Australia/Lord_Howe", now).as_deref().map(|s| s.contains("30 minutes")),
            Some(true)
        );
    }

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_751), (2026, 10, 25));
    }
}
