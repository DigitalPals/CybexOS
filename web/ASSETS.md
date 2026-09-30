# Browser experience asset sources

| Asset | Source | Rights information |
| --- | --- | --- |
| `public/wallpapers/moon-mountains.jpg` | Copied from `../assets/wallpapers/snow-capped-mountains-with-full-moon-lo.jpg`; selected by the native `assets/desktop-contract.json` | The repository does not identify an author or license for this image. This document records its provenance and does not grant or infer redistribution rights. |
| `public/cybex-wordmark.svg` | Copied from `../image/rootfs/usr/share/cybexos/welcome/cybex-wordmark.svg` | Existing Cybex brand asset; no additional license is asserted here. |
| Figtree | `@fontsource/figtree`, installed through the npm lockfile | SIL Open Font License 1.1. Copyright 2022 The Figtree Project Authors, https://github.com/erikdkennedy/figtree. The full license is also shipped in `public/licenses/`. |
| JetBrains Mono | `@fontsource/jetbrains-mono`, installed through the npm lockfile | SIL Open Font License 1.1. Copyright 2020 The JetBrains Mono Project Authors, https://github.com/JetBrains/JetBrainsMono. The full license is also shipped in `public/licenses/`. |
| Interface icons | `lucide-react`, installed through the npm lockfile | ISC license and included upstream notices; the complete license and Feather notices are shipped in `public/licenses/lucide.txt`. |

Font files are bundled and served with the application. They do not depend on
a remote font CDN. Procedural wallpaper choices are drawn with CSS.

Do not apply a repository-wide code license to third-party images or brand
marks without checking their original terms. Replace the mountain photograph
with a rights-cleared image if its existing provenance is insufficient for a
particular distribution.
