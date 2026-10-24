//! Copy cached software frames to scanout without reading display memory.
//!
//! Nix copies this module into the pinned KMS backend's private vendor tree.
//! The integration tests compile this exact file. Damage is already in physical
//! framebuffer coordinates, including rotation; row padding is never a pixel.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Layout {
    pub width: usize,
    pub height: usize,
    pub stride_bytes: usize,
    pub bytes_per_pixel: usize,
}

#[derive(Clone, Copy, Debug)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Default)]
pub struct DamageHistory {
    layout: Option<Layout>,
    // Three scanout buffers require the current damage and two earlier frames.
    previous: [Option<Vec<Rect>>; 2],
}

impl DamageHistory {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Return bytes written. Unknown ages/layouts get a complete cached frame.
    pub fn copy_to_scanout(
        &mut self,
        shadow: &[u8],
        scanout: &mut [u8],
        layout: Layout,
        age: u8,
        mut damage: Vec<Rect>,
    ) -> usize {
        assert_eq!(shadow.len(), scanout.len());
        assert!(layout.bytes_per_pixel > 0);
        assert!(layout.width * layout.bytes_per_pixel <= layout.stride_bytes);
        assert_eq!(layout.stride_bytes * layout.height, scanout.len());

        let changed_layout = self.layout != Some(layout);
        if changed_layout {
            self.previous = Default::default();
            // Other scanout buffers may still contain the preceding layout.
            damage = vec![Rect {
                x: 0,
                y: 0,
                width: layout.width.try_into().expect("framebuffer width"),
                height: layout.height.try_into().expect("framebuffer height"),
            }];
        }
        let previous_count = usize::from(age.saturating_sub(1));
        let full = changed_layout
            || age == 0
            || previous_count > self.previous.len()
            || self.previous[..previous_count.min(self.previous.len())]
                .iter()
                .any(Option::is_none);

        let copied = if full {
            scanout.copy_from_slice(shadow);
            shadow.len()
        } else {
            let mut copied = 0;
            for rect in damage
                .iter()
                .chain(self.previous[..previous_count].iter().flatten().flatten())
            {
                let x0 = i64::from(rect.x).clamp(0, layout.width as i64) as usize;
                let y0 = i64::from(rect.y).clamp(0, layout.height as i64) as usize;
                let x1 = (i64::from(rect.x) + i64::from(rect.width)).clamp(0, layout.width as i64)
                    as usize;
                let y1 = (i64::from(rect.y) + i64::from(rect.height)).clamp(0, layout.height as i64)
                    as usize;
                for y in y0..y1 {
                    let row = y * layout.stride_bytes;
                    let span = row + x0 * layout.bytes_per_pixel..row + x1 * layout.bytes_per_pixel;
                    // Source is cached RAM. Never blend with or read scanout.
                    scanout[span.clone()].copy_from_slice(&shadow[span.clone()]);
                    copied += span.len();
                }
            }
            copied
        };

        self.previous.rotate_right(1);
        self.previous[0] = Some(damage);
        self.layout = Some(layout);
        copied
    }
}
