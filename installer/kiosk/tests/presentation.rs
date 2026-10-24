//! Exercise the exact damage-copy module used by the patched KMS backend.
#[path = "../kms-shadow.rs"]
mod shadow;

use shadow::{DamageHistory, Layout, Rect};

fn rect(x: i32, y: i32, width: u32, height: u32) -> Rect {
    Rect {
        x,
        y,
        width,
        height,
    }
}

#[test]
fn three_scanout_buffers_keep_all_intervening_changes_without_full_copies() {
    for bytes_per_pixel in [2, 4] {
        let layout = Layout {
            width: 64,
            height: 32,
            stride_bytes: 64 * bytes_per_pixel + 16,
            bytes_per_pixel,
        };
        let mut shadow = vec![0; layout.stride_bytes * layout.height];
        let mut buffers = vec![vec![0xaa; shadow.len()]; 3];
        let mut history = DamageHistory::default();
        let mut previous_cursor = None;
        for frame in 0..30 {
            let x = (frame * 7) % 60;
            let y = (frame * 3) % 28;
            let mut damage = vec![rect(x as i32, y as i32, 4, 4)];
            if let Some((old_x, old_y)) = previous_cursor {
                damage.push(rect(old_x as i32, old_y as i32, 4, 4));
            }
            shadow.fill(0);
            for row in y..y + 4 {
                let start = row * layout.stride_bytes + x * bytes_per_pixel;
                shadow[start..start + 4 * bytes_per_pixel].fill(0xff);
            }
            let buffer = &mut buffers[frame % 3];
            let copied = history.copy_to_scanout(
                &shadow,
                buffer,
                layout,
                if frame < 3 { 0 } else { 3 },
                damage,
            );
            assert_eq!(*buffer, shadow, "stale cursor or content in frame {frame}");
            if frame >= 3 {
                assert!(
                    copied < shadow.len() / 4,
                    "three-buffer age forced a full copy"
                );
            }
            previous_cursor = Some((x, y));
        }
    }
}

#[test]
fn unknown_ages_and_missing_history_reconstruct_the_whole_frame() {
    let layout = Layout {
        width: 4,
        height: 3,
        stride_bytes: 20,
        bytes_per_pixel: 4,
    };
    let shadow = vec![7; 60];
    for age in [0, 1, 2, 3, 4, 255] {
        let mut history = DamageHistory::default();
        let mut scanout = vec![0; 60];
        assert_eq!(
            history.copy_to_scanout(&shadow, &mut scanout, layout, age, vec![]),
            60
        );
        assert_eq!(scanout, shadow);
    }
    let mut history = DamageHistory::default();
    let mut scanout = vec![0; 60];
    history.copy_to_scanout(&shadow, &mut scanout, layout, 0, vec![]);
    history.reset();
    scanout.fill(0);
    assert_eq!(
        history.copy_to_scanout(&shadow, &mut scanout, layout, 1, vec![]),
        60
    );
    assert_eq!(scanout, shadow);
}

#[test]
fn partial_copies_clip_physical_damage_and_preserve_row_padding() {
    // Physical coordinates, as returned after a 90/270-degree render rotation.
    let layout = Layout {
        width: 3,
        height: 7,
        stride_bytes: 16,
        bytes_per_pixel: 4,
    };
    let mut history = DamageHistory::default();
    let mut scanout = vec![0; 112];
    history.copy_to_scanout(&vec![0x11; 112], &mut scanout, layout, 0, vec![]);
    let mut expected = scanout.clone();
    for y in 1..5 {
        expected[y * 16..y * 16 + 8].fill(0xee);
    }
    let copied = history.copy_to_scanout(
        &vec![0xee; 112],
        &mut scanout,
        layout,
        1,
        vec![rect(-1, 1, 3, 4), rect(20, 20, 2, 2)],
    );
    assert_eq!(copied, 32);
    assert_eq!(scanout, expected);
    assert_eq!(
        history.copy_to_scanout(&vec![0; 112], &mut scanout, layout, 1, vec![]),
        0
    );
    assert_eq!(scanout, expected, "an empty frame changed pixels");
}

#[test]
fn changed_pitch_or_pixel_format_invalidates_history() {
    let mut history = DamageHistory::default();
    let mut scanout = vec![0; 48];
    let old = Layout {
        width: 4,
        height: 3,
        stride_bytes: 16,
        bytes_per_pixel: 4,
    };
    history.copy_to_scanout(&vec![1; 48], &mut scanout, old, 0, vec![]);
    let changed = Layout {
        width: 6,
        height: 3,
        stride_bytes: 16,
        bytes_per_pixel: 2,
    };
    assert_eq!(
        history.copy_to_scanout(&vec![2; 48], &mut scanout, changed, 1, vec![]),
        48
    );
    assert_eq!(scanout, vec![2; 48]);
}
