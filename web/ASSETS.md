# Browser experience asset sources

| Asset | Source | Rights information |
| --- | --- | --- |
| `public/wallpapers/moon-mountains.jpg` | Copied from `../assets/wallpapers/snow-capped-mountains-with-full-moon-lo.jpg`; selected by the native `assets/desktop-contract.json` | The repository does not identify an author or license for this image. This document records its provenance and does not grant or infer redistribution rights. |
| `public/cybex-wordmark.svg` | Copied from `../image/rootfs/usr/share/cybexos/welcome/cybex-wordmark.svg` | Existing Cybex brand asset; no additional license is asserted here. |
| `public/fedora.svg` | Unchanged copy of `../roles/desktop/files/quickshell/assets/fedora.svg`, adapted from the Fedora Design Team mark at revision `e7ee4e88ac5b43a1acf2ab39157b63c80e8093f2` | CC BY-SA 4.0, except trademark rights. Attribution, modification history, and license link are in `public/licenses/fedora-mark.txt`. |
| Figtree | `@fontsource/figtree`, installed through the npm lockfile | SIL Open Font License 1.1. Copyright 2022 The Figtree Project Authors, https://github.com/erikdkennedy/figtree. The full license is also shipped in `public/licenses/`. |
| JetBrains Mono | `@fontsource/jetbrains-mono`, installed through the npm lockfile | SIL Open Font License 1.1. Copyright 2020 The JetBrains Mono Project Authors, https://github.com/JetBrains/JetBrainsMono. The full license is also shipped in `public/licenses/`. |
| Interface icons | `lucide-react`, installed through the npm lockfile | ISC license and included upstream notices; the complete license and Feather notices are shipped in `public/licenses/lucide.txt`. |

Font files are bundled and served with the application. They do not depend on
a remote font CDN. Procedural wallpaper choices are drawn with CSS.

Do not apply a repository-wide code license to third-party images or brand
marks without checking their original terms. Replace the mountain photograph
with a rights-cleared image if its existing provenance is insufficient for a
particular distribution.

## Model Usage provider marks

`public/providers/codex.svg` and `public/providers/claude.svg` are unchanged
copies from the native `roles/desktop/files/quickshell/ModelUsage/assets/`
widget. Its notices identify their source as `basecamp/omarchy` commit
`2c247e390e357ae0fee3f8565b0c816adb705e6a` (MIT). The corresponding notice is
shipped at `public/licenses/model-usage-marks.txt`. Provider marks belong to
their owners and do not imply affiliation or endorsement.
