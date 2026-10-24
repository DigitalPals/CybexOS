//! The dot-matrix world map behind the time zone picker.
//!
//! Land cells come from `assets/landmask.txt` (Natural Earth 1:110m land,
//! public domain, sampled on a 2° equirectangular grid). Each dot is shaded
//! by the sun's elevation at its centre: day, twilight or night. The map is
//! rasterized into a pixel buffer only when the selection, the pins or the
//! minute changes; nothing animates.

use slint::{Rgba8Pixel, SharedPixelBuffer};

pub struct LandMask {
    pub step: f64,
    pub top: f64,
    pub rows: Vec<Vec<bool>>,
}

impl LandMask {
    pub fn embedded() -> Self {
        Self::parse(include_str!("../assets/landmask.txt"))
    }

    pub fn parse(text: &str) -> Self {
        let mut step = 2.0;
        let mut top = 82.0;
        let mut rows = Vec::new();
        for line in text.lines() {
            if let Some(header) = line.strip_prefix("# step=") {
                for (index, field) in header.split_whitespace().enumerate() {
                    let value = field.split('=').next_back().unwrap_or(field);
                    match index {
                        0 => step = value.parse().unwrap_or(step),
                        1 => top = value.parse().unwrap_or(top),
                        _ => {}
                    }
                }
                continue;
            }
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let mut row = Vec::new();
            for (index, run) in line.split('.').enumerate() {
                let count: usize = run.parse().unwrap_or(0);
                row.extend(std::iter::repeat(index % 2 == 1).take(count));
            }
            rows.push(row);
        }
        LandMask { step, top, rows }
    }

    pub fn cols(&self) -> usize {
        self.rows.first().map_or(0, Vec::len)
    }
}

/// Sub-solar point for a Unix time: (declination, longitude) in degrees.
pub fn sun(now: i64) -> (f64, f64) {
    let days = now.div_euclid(86_400);
    let (year, _, _) = crate::zones::civil_from_days(days);
    let day_zero = days_from_civil(year, 1, 1) - 1;
    let doy = (days - day_zero) as f64 + (now.rem_euclid(86_400) as f64) / 86_400.0;
    let declination = -23.44 * (2.0 * std::f64::consts::PI / 365.0 * (doy + 10.0)).cos();
    let hours = now.rem_euclid(86_400) as f64 / 3600.0;
    (declination, (12.0 - hours) * 15.0)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn elevation(lat: f64, lon: f64, sun: (f64, f64)) -> f64 {
    let (decl, sub_lon) = sun;
    let (lat, decl) = (lat.to_radians(), decl.to_radians());
    let hour_angle = (lon - sub_lon).to_radians();
    (lat.sin() * decl.sin() + lat.cos() * decl.cos() * hour_angle.cos()).asin().to_degrees()
}

pub struct Marker {
    pub lat: f64,
    pub lon: f64,
}

const DAY: [u8; 3] = [0xb4, 0xb7, 0xac];
const TWILIGHT: [u8; 3] = [0x6d, 0x70, 0x69];
const NIGHT: [u8; 3] = [0x34, 0x36, 0x3b];
const PIN: [u8; 3] = [0xf3, 0xf2, 0xec];
const ACCENT: [u8; 3] = [0x60, 0xa5, 0xfa];

pub struct Canvas {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<[u8; 4]>,
}

impl Canvas {
    fn new(width: u32, height: u32) -> Self {
        Canvas { width, height, pixels: vec![[0, 0, 0, 0]; (width * height) as usize] }
    }

    fn blend(&mut self, x: i64, y: i64, rgb: [u8; 3], alpha: f64) {
        if x < 0 || y < 0 || x >= self.width as i64 || y >= self.height as i64 || alpha <= 0.0 {
            return;
        }
        let p = &mut self.pixels[(y as u32 * self.width + x as u32) as usize];
        let a = alpha.min(1.0);
        let base_a = p[3] as f64 / 255.0;
        let out_a = a + base_a * (1.0 - a);
        for c in 0..3 {
            let src = rgb[c] as f64 * a;
            let dst = p[c] as f64 * base_a * (1.0 - a);
            p[c] = if out_a > 0.0 { ((src + dst) / out_a).round() as u8 } else { 0 };
        }
        p[3] = (out_a * 255.0).round() as u8;
    }

    /// Anti-aliased filled circle.
    fn disc(&mut self, cx: f64, cy: f64, r: f64, rgb: [u8; 3], alpha: f64) {
        let (x0, x1) = ((cx - r - 1.0).floor() as i64, (cx + r + 1.0).ceil() as i64);
        let (y0, y1) = ((cy - r - 1.0).floor() as i64, (cy + r + 1.0).ceil() as i64);
        for y in y0..=y1 {
            for x in x0..=x1 {
                let d = ((x as f64 + 0.5 - cx).powi(2) + (y as f64 + 0.5 - cy).powi(2)).sqrt();
                let coverage = (r + 0.5 - d).clamp(0.0, 1.0);
                if coverage > 0.0 {
                    self.blend(x, y, rgb, alpha * coverage);
                }
            }
        }
    }

    fn hline(&mut self, y: f64, rgb: [u8; 3], alpha: f64) {
        for x in 0..self.width as i64 {
            self.blend(x, y.round() as i64, rgb, alpha);
        }
    }

    fn vline(&mut self, x: f64, rgb: [u8; 3], alpha: f64) {
        for y in 0..self.height as i64 {
            self.blend(x.round() as i64, y, rgb, alpha);
        }
    }

    pub fn into_buffer(self) -> SharedPixelBuffer<Rgba8Pixel> {
        let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(self.width, self.height);
        for (dst, src) in buffer.make_mut_slice().iter_mut().zip(self.pixels) {
            // Slint expects premultiplied alpha for RGBA8 pixel buffers.
            let a = src[3] as u16;
            *dst = Rgba8Pixel {
                r: ((src[0] as u16 * a + 127) / 255) as u8,
                g: ((src[1] as u16 * a + 127) / 255) as u8,
                b: ((src[2] as u16 * a + 127) / 255) as u8,
                a: src[3],
            };
        }
        buffer
    }
}

impl LandMask {
    pub fn position(&self, lat: f64, lon: f64, width: f64, height: f64) -> (f64, f64) {
        let cols = self.cols() as f64;
        let rows = self.rows.len() as f64;
        let x = (lon + 180.0) / self.step * (width / cols);
        let y = ((self.top - lat) / self.step + 0.5) * (height / rows);
        (x, y)
    }

    /// Inverse of `position`, for clicks: fractions of the map size.
    pub fn coordinates(&self, fx: f64, fy: f64) -> (f64, f64) {
        let rows = self.rows.len() as f64;
        (self.top - (fy * rows - 0.5) * self.step, fx * 360.0 - 180.0)
    }

    pub fn render(&self, width: u32, height: u32, now: i64, pins: &[Marker], selected: Option<&Marker>) -> Canvas {
        let mut canvas = Canvas::new(width, height);
        let (w, h) = (width as f64, height as f64);
        let cw = w / self.cols() as f64;
        let ch = h / self.rows.len() as f64;
        let r = cw.min(ch) * 0.34;
        let sun = sun(now);
        for (i, row) in self.rows.iter().enumerate() {
            let lat = self.top - i as f64 * self.step;
            for (j, land) in row.iter().enumerate() {
                if !land {
                    continue;
                }
                let lon = -180.0 + self.step / 2.0 + j as f64 * self.step;
                let e = elevation(lat, lon, sun);
                let rgb = if e > 0.0 { DAY } else if e > -6.0 { TWILIGHT } else { NIGHT };
                canvas.disc((j as f64 + 0.5) * cw, (i as f64 + 0.5) * ch, r, rgb, 1.0);
            }
        }
        for pin in pins {
            let (x, y) = self.position(pin.lat, pin.lon, w, h);
            canvas.disc(x, y, r * 0.95, PIN, 0.9);
        }
        if let Some(sel) = selected {
            let (x, y) = self.position(sel.lat, sel.lon, w, h);
            canvas.vline(x, ACCENT, 0.22);
            canvas.hline(y, ACCENT, 0.22);
            canvas.disc(x, y, r * 5.0, ACCENT, 0.18);
            canvas.disc(x, y, r * 1.9, ACCENT, 1.0);
        }
        canvas
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mask_has_the_expected_grid_and_known_land() {
        let mask = LandMask::embedded();
        assert_eq!(mask.rows.len(), 70);
        assert_eq!(mask.cols(), 180);
        assert!(mask.rows.iter().all(|r| r.len() == 180));
        let land = |lat: f64, lon: f64| {
            let i = ((mask.top - lat) / mask.step).round() as usize;
            let j = ((lon + 180.0 - mask.step / 2.0) / mask.step).round() as usize;
            mask.rows[i][j]
        };
        assert!(land(52.0, 5.0), "the Netherlands is land");
        assert!(!land(30.0, -40.0), "the mid-Atlantic is water");
        assert!(land(-25.0, 135.0), "Australia is land");
    }

    #[test]
    fn day_and_night_follow_the_sun() {
        // 2026-10-23 19:18 UTC: the Americas are in daylight, Asia is dark.
        let now = 1_792_783_080;
        let s = sun(now);
        assert!(elevation(40.0, -100.0, s) > 20.0);
        assert!(elevation(30.0, 100.0, s) < -40.0);
    }

    #[test]
    fn click_coordinates_invert_positions() {
        let mask = LandMask::embedded();
        let (x, y) = mask.position(52.37, 4.9, 1000.0, 389.0);
        let (lat, lon) = mask.coordinates(x / 1000.0, y / 389.0);
        assert!((lat - 52.37).abs() < 0.01 && (lon - 4.9).abs() < 0.01);
        let canvas = mask.render(360, 140, 0, &[], Some(&Marker { lat: 52.37, lon: 4.9 }));
        assert_eq!(canvas.pixels.len(), 360 * 140);
    }
}
