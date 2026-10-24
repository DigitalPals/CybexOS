//! Display zoom: the 1280×800 design canvas fitted to the panel.
//!
//! The same rule as the Tiaris kiosk: the largest connected DRM mode decides,
//! 1920×1200 → 1.5, 2880×1800 → 2.25, 3840×2160 → 2.7, never below 0.8.

pub const CANVAS: (f32, f32) = (1280.0, 800.0);

pub fn detect_resolution() -> Option<(u32, u32)> {
    if let Ok(value) = std::env::var("NERDOS_INSTALLER_RESOLUTION") {
        if let Some((w, h)) = value.split_once('x') {
            if let (Ok(w), Ok(h)) = (w.parse(), h.parse()) {
                return Some((w, h));
            }
        }
    }
    let mut best: Option<(u32, u32)> = None;
    for entry in std::fs::read_dir("/sys/class/drm").ok()?.flatten() {
        let path = entry.path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if !(name.starts_with("card") && name.contains('-')) {
            continue;
        }
        if std::fs::read_to_string(path.join("status")).map(|s| s.trim() != "connected").unwrap_or(true) {
            continue;
        }
        let Some(mode) = std::fs::read_to_string(path.join("modes")).ok().and_then(|m| m.lines().next().map(str::to_owned)) else {
            continue;
        };
        if let Some((w, h)) = mode.split_once('x') {
            let h = h.trim_end_matches(|c: char| !c.is_ascii_digit());
            if let (Ok(w), Ok(h)) = (w.parse::<u32>(), h.parse::<u32>()) {
                if best.is_none_or(|(bw, bh)| w * h > bw * bh) {
                    best = Some((w, h));
                }
            }
        }
    }
    best
}

pub fn zoom_for(resolution: Option<(u32, u32)>) -> f32 {
    let Some((width, height)) = resolution else {
        return 1.0;
    };
    let fit = (width as f32 / CANVAS.0).min(height as f32 / CANVAS.1);
    (fit.clamp(0.8, 3.0) * 100.0).round() / 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zoom_fits_the_design_canvas() {
        assert_eq!(zoom_for(Some((1280, 800))), 1.0);
        assert_eq!(zoom_for(Some((1920, 1200))), 1.5);
        assert_eq!(zoom_for(Some((1920, 1080))), 1.35);
        assert_eq!(zoom_for(Some((2880, 1800))), 2.25);
        assert_eq!(zoom_for(Some((3840, 2160))), 2.7);
        assert_eq!(zoom_for(Some((1024, 600))), 0.8);
        assert_eq!(zoom_for(None), 1.0);
    }
}
