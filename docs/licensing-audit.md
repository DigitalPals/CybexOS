# Third-party redistribution audit

This is an engineering inventory of the third-party components that CybexOS
installs, and of what a public ISO would redistribute. It records the license
tags, upstream license files, and vendor terms that could be checked, and marks
everything else **Unverified**. It is not a legal opinion and grants no rights.
The owner, with legal review where needed, must decide every item before a
public ISO, desktop RPM, or source archive is published. See
[licensing and asset provenance](licensing.md) for the repository's own license.

## Audit basis

- Repository state of 2026-10-13, based on commit `b0a97b7`.
- Package selections were read from `image/applications` (`package_names()` and
  `PACKAGE_TASKS`), `image/live.ks`, `roles/base/defaults/main.yml`,
  `roles/apps/defaults/main.yml`, `roles/apps/tasks/*.yml`, and
  `roles/desktop/tasks/main.yml`. Pinned downloads were read from
  `inventory/group_vars/all.yml`.
- License tags and source repositories come from a `dnf repoquery` of Fedora
  44, RPM Fusion free and nonfree, the Brave, 1Password, ChatGPT and Tailscale
  repositories, and the `sdegler/hyprland` COPR on 2026-10-13. A tag is the
  packager's declaration, not a review of the package contents.
- Upstream licenses were read from the pinned upstream repositories. Vendor
  terms were read from the vendors' public pages on 2026-10-13; quotations are
  excerpts.
- Evidence of what an image actually contained comes from the retained package
  list and payload file manifest of the 2026-09-25 build
  `20260925T140839Z-5f33cb32` (revision `a2d31c2c13b5`). That build predates
  later selections, including `gstreamer1-plugin-openh264` and the XPS
  packages, so it does not describe the current payload. No current image was
  built or inspected for this audit.

"Bundled" means the bytes are inside the ISO: an RPM composed into the image,
the Flatpak installation copied from the builder, or the offline application
seed (`/opt/cybexos-apps`, `/opt/cybexos-builds`, `/usr/local/share/fonts`,
`/usr/share/cybexos/user-seed`). "Downloaded" means the user's machine fetches
the component from its upstream at installation or first use.

## Distribution channels

| Channel | Third-party content it redistributes |
| --- | --- |
| Public Git repository and source archive | Wallpapers, brand SVGs, Plymouth artwork, the Tabler icon font subset, vendored MIT code (Omarchy adapter, Model Usage, T3 Code-derived logic), and repository keys for RPM Fusion and ChatGPT |
| `cybexos-desktop` RPM | The repository content above that the desktop needs, including all wallpapers in the user seed and the Plymouth theme |
| ISO | Everything above, every composed RPM and its dependencies, the system Flatpak installation, and the offline application seed |
| Source checkout (`./install`) | Repository content only; every application, font, and toolchain is downloaded by the user's machine from its upstream |

The checkout path therefore redistributes much less than the ISO. It still
automates license acceptance for the Android SDK (see below) and installs the
same repository assets.

## RPM packages by repository

| Repository | Packages CybexOS selects | License tags (repoquery) | ISO | Checkout |
| --- | --- | --- | --- | --- |
| Fedora 44 (`fedora`, `updates`) | About 300 named packages plus dependencies: the shared baseline, desktop, applications, developer tools, fonts, firmware, Docker (`moby-engine`), Podman, Java 25 | Fedora-approved licenses; firmware uses `LicenseRef-Fedora-Firmware` | Bundled | Downloaded |
| Fedora Cisco OpenH264 (`fedora-cisco-openh264`) | `openh264`, a possible provider of the library that `gstreamer1-plugin-openh264` needs; Fedora's `noopenh264` stub is the other | `BSD-2-Clause`; Cisco binary, see codecs below | Repository enabled in `image/build.repo`; selected provider **Unverified** | Downloaded from Cisco |
| RPM Fusion free | `rpmfusion-free-release`, `ffmpeg`, `ffmpeg-libs`, `x264-libs`, `x265-libs` | `GPLv2+`, `GPLv3+`, `GPLv2+ and BSD` | Bundled | Downloaded |
| RPM Fusion nonfree | `rpmfusion-nonfree-release`, `steam`, `intel-media-driver` | `Steam License Agreement`; `MIT and BSD` | Bundled (`intel-media-driver` on every image, not only XPS hardware) | Downloaded (`intel-media-driver` only on detected XPS hardware) |
| Brave | `brave-origin`, `brave-keyring` | `Multiple, see https://brave.com/` | Bundled | Downloaded |
| 1Password | `1password`, `1password-cli` | `LicenseRef-1Password-Proprietary` | Bundled | Downloaded |
| OpenAI ChatGPT | `chatgpt` | `Proprietary` | Bundled | Downloaded |
| Tailscale | `tailscale` | `MIT`; upstream source is BSD-3-Clause | Bundled | Downloaded |
| COPR `sdegler/hyprland` | `hyprland`, `hypridle`, `hyprlock`, `hyprpicker`, `hyprsunset`, `xdg-desktop-portal-hyprland`; it also offers `cliphist`, `satty`, `nwg-look` and `matugen`, while `fuzzel` and `matugen` are deliberately installed from Fedora | BSD-3-Clause, MIT, GPL and similar | Bundled | Downloaded |
| Local build repository | `cybexos-desktop` (this repository), `mdview` (DigitalPals/mdview), `voxtype` (MIT) pinned GitHub release RPMs | `mdview`: no license file in its repository, **Unverified** | Bundled | Downloaded |

The 2026-09-25 package list contained 1,700 packages. A complete per-package
license report for the actual release payload has not been produced.

## Proprietary and non-RPM applications

| Component | License or terms | ISO | Checkout | Status |
| --- | --- | --- | --- | --- |
| Brave Origin | Brave's terms grant "a personal, non-exclusive license to install and use the executable code version of the Brave browser" and no right to use Brave's marks; source parts are MPL-2.0 | Bundled | Downloaded | No redistribution grant located |
| 1Password and CLI | Proprietary RPM tag; the individual terms allow use "only for your own non-commercial use", the business terms (4.2) prohibit distributing "any part or content of the Services" | Bundled | Downloaded | No redistribution grant located |
| ChatGPT desktop | Proprietary RPM tag; OpenAI's terms page refused automated access | Bundled | Downloaded | Terms **Unverified**; no grant located |
| Spotify (`com.spotify.Client`) | Flathub declares `LicenseRef-proprietary` (Spotify end-user agreement), and the Flatpak fetches Spotify's binary as extra data at install time. The agreement (section 3) says "You agree that you will not redistribute, sell or transfer the Spotify Service or the Content." | Bundled: the image copies the builder's installed Flatpaks, including the downloaded binary | Downloaded by Flatpak | Conflicts with the quoted terms |
| Steam | RPM Fusion's spec states "Redistribution and repackaging for Linux is allowed, see license file"; the shipped license file is the Steam Subscriber Agreement, whose section 2.G restricts distribution without Valve's written consent. No explicit launcher grant was found. | Launcher and bootstrap bundled; client and games downloaded at first launch | Downloaded | **Unverified** |
| Android SDK (command-line tools, platform-tools, build-tools, platforms) | Android SDK License Agreement 3.4: "you may not copy (except for backup purposes), modify, adapt, redistribute ... the SDK or any part of the SDK"; 2.1 requires agreeing before use. `android-sdk-update` runs `yes \| sdkmanager --licenses`, and the 2026-09-25 seed contained more than 11,700 SDK files and `licenses/android-sdk-license`. | Bundled in the user seed | Downloaded; acceptance automated | Conflicts with the quoted terms; acceptance is made on the user's behalf on both paths |
| Claude Code 2.1.247 | Upstream `LICENSE.md`: "© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service." Those terms (D.4) prohibit reselling the Services without approval and contain no redistribution grant. | Bundled in the user seed | Downloaded from Anthropic | No redistribution grant located |
| Codex CLI | Apache-2.0 (`openai/codex`); tracks npm `latest`, so each image may contain a different version | Bundled | Downloaded | Redistributable with notices |
| OpenCode 1.18.27 | MIT (`anomalyco/opencode`) | Bundled | Downloaded | Redistributable with notices |
| T3 Code Nightly | MIT (`pingdotgg/t3code`); the AppImage also contains Electron and Chromium components with their own notices, **Unverified** | Bundled | Downloaded | Redistributable with notices |
| Rust nightly toolchain | MIT or Apache-2.0; Rust trademark policy not reviewed | Bundled | Downloaded | Redistributable with notices |
| Voxtype `ggml-base.bin` model | Whisper weights are MIT (`openai/whisper`); download source and checksum are not pinned in the inventory | Bundled | Downloaded at install | Record source and checksum |
| LocalSend, ProtonUp-Qt (Flathub) | Apache-2.0; GPL-3.0 | Bundled | Downloaded | Redistributable; GPL source obligation |
| Flatpak runtimes | Mostly free software. A Freedesktop runtime may pull the `org.freedesktop.Platform.openh264` extension, which downloads Cisco's binary as extra data. | Bundled with the whole system Flatpak tree; contents **Unverified** | Downloaded | Inspect the built image |
| lazygit, lazydocker, oh-my-posh | MIT | Bundled | Downloaded | Redistributable with notices |
| Bun | MIT; statically links LGPL-2 JavaScriptCore, with upstream relinking instructions | Bundled | Downloaded | Redistributable; LGPL obligations |
| balena CLI | Apache-2.0; the standalone bundle contains Node.js and many npm packages, notices **Unverified** | Bundled | Downloaded | Redistributable with notices |
| Omawrite | MIT (`omacom/omawrite`), built from source | Bundled | Built locally | Redistributable with notices |
| awww, wayfreeze | GPL-3.0; AGPL-3.0; built from pinned source | Bundled | Built locally | Corresponding source must be offered |
| LazyVim starter | Apache-2.0 | Bundled | Downloaded | Redistributable with notices |

Downloaded only, never bundled: the Steam client and games, Wallhaven images
in the welcome window, the Firefox 1Password extension, Distrobox images, and
the XPS IPU7 camera stack (including `intel/ipu7-camera-bins`), which is fetched
only on detected XPS hardware. The optional private hooks, off by default,
download the Conthrax font; they are not part of the ISO.

## Fonts

| Font | Source | License | Notes |
| --- | --- | --- | --- |
| JetBrainsMono and FiraCode Nerd Fonts 3.5.1 | `ryanoasis/nerd-fonts` release archives | OFL-1.1 for patched fonts | The archive `LICENSE` is kept beside the fonts |
| iA Writer Mono, Duo, Quattro, Duospace | `iaolo/iA-Fonts`, pinned commits | OFL-1.1, Reserved Font Names "iA Writer" and "Plex" | License installed beside each font |
| Figtree 1.2, Geist Mono 1.5.0, Urbanist 1.321 | Pinned upstream commits | OFL-1.1 | License installed beside each font |
| Google Sans Flex | `end-4/google-sans-flex`, an unofficial mirror | Mirror README says OFL-1.1, but its `LICENSE` is the unfilled OFL template without a copyright line. Google's `google/fonts` repository (`ofl/googlesansflex`) has an `OFL.txt` with a copyright notice and a `TRADEMARKS.md`. | Source from the official repository |
| OPPO Sans 4.0 | OPPO archive, pinned by SHA-256 | OPPO Sans Fonts License Agreement | See below |
| Tabler outline subset | `@tabler/icons-webfont` 3.48.0, in the shell | MIT | License shipped in `assets/tabler/` |
| Fedora font packages | Fedora 44 | OFL-1.1 for most; `OFL-1.1-RFN` (Liberation); MIT (`fontawesome-fonts-all`); CC-BY-4.0 (`fontawesome-fonts-web`); Apache-2.0 (Open Sans); `GPL-1.0-or-later` (Madan); `GPL-2.0-only WITH Font-exception-2.0` (PakType Naskh Basic); `LicenseRef-Fedora-UltraPermissive` (Symbola) | Redistributed under Fedora's packaging |

The OPPO Sans agreement grants a revocable license to "use, copy, merge, embed,
bundle, redistribute and/or sell unmodified copies of OPPO Sans Fonts with any
software except for fonts software", on conditions that include: "YOU shall
make a prominent notice in the software to state that OPPO Sans Fonts are
used", no modification, no stand-alone redistribution, and retaining the
copyright notice and agreement. The agreement file is installed beside the
font, but no notice inside CybexOS was found.

## Wallpapers and artwork

`assets/PROVENANCE.json` lists seven wallpapers. All have unknown creator,
source URL, and license; the inventory's rights status is
`unknown-owner-action-required`. They are installed on both paths, shipped in
the desktop RPM's user seed, and already published in the public repository.

| File | Apparent subject, judged only from the file name | Creator, source, license |
| --- | --- | --- |
| `01-black-widow-warrior-with-katana-ks.jpg` | Black Widow, a Marvel character | Unknown |
| `05-joker-chaos-in-a-purple-suit-nq.jpg` | The Joker, a DC character | Unknown |
| `diana-prince-amazonian-legend-hn.jpg` | Diana Prince (Wonder Woman), a DC character | Unknown |
| `joker-ghost-in-dark-rt.jpg` | The Joker, a DC character | Unknown |
| `snow-capped-mountains-with-full-moon-lo.jpg` | Mountains and moon; the default wallpaper | Unknown |
| `spider-man-guardian-of-the-skyline-yx.jpg` | Spider-Man, a Marvel character | Unknown |
| `spider-man-the-hero-beyond-the-stars-cx.jpg` | Spider-Man, a Marvel character | Unknown |

The images were not inspected; the subjects come from file names only. Six
appear to depict copyrighted and trademarked characters. The browser demo
serves the default wallpaper as `web/public/wallpapers/moon-mountains.jpg`
(same SHA-256), outside the inventory's scope, which only covers `assets/`.

The Plymouth theme in `roles/boot/files` (logo, entry, bullet and progress
images, and the script) is shipped in the desktop RPM. The checkout role also
uses the pinned `DigitalPals/omarchy-cybex` repository, which has no license
file. The Cybex wordmark SVGs are in the welcome window, the live installer,
and the browser demo. These files are below the 1 MiB inventory threshold and
have no recorded provenance; the owner should confirm authorship.

## Brand icons and trademarks

The shell's product marks are listed with their sources in
`roles/desktop/files/quickshell/assets/README.md` and
`THIRD_PARTY_LICENSES.md`: Simple Icons (CC0) for Claude, Gemini, GitHub, Kimi,
Tailscale, WhatsApp and YouTube; Tabler (MIT) for OpenAI and Slack; MIT
sources for Grok and T3 Code; the Unlicense for Fusebox; and Fedora Design
artwork (CC BY-SA 4.0) for Fedora. The Model Usage widget redistributes the
Claude and Codex marks from Omarchy (MIT), and the browser demo serves
Fedora, Claude and Codex marks. These licenses cover copyright only. The
trademark guidelines of the individual brands were not reviewed
(**Unverified**).

Fedora's [trademark guidelines](https://docs.fedoraproject.org/en-US/legal/trademarks/)
allow software that combines Fedora with other software to use the "Fedora
Remix" marks provided that "the fedora-logos, fedora-release, and
fedora-release-notes RPM packages are removed" (replacements must not contain
Fedora trademarks) and that a notice prominently states that the software is
not provided or supported by the Fedora Project and links to
<https://fedoraproject.org/>. Their general conditions add that "no other
Fedora Trademarks are used for remix products". Findings:

- `image/live.ks` installs `generic-logos` and `generic-release-notes`, and
  `fedora-logos` was absent from the 2026-09-25 package list.
- `image/live.ks` also installs `fedora-release-common` and
  `fedora-release-identity-basic`, which set the operating system name to
  Fedora Linux. The 2026-09-25 list also contained the `fedora-release`
  metapackage. Fedora's `generic-release` replaces them with a placeholder
  identity (`ID=generic`, `ID_LIKE=fedora`), but CybexOS code checks for
  `ID=fedora` in `cybexos-update-channel`, `cybexos-major-upgrade`, and the
  shell's system information. A dedicated release package needs engineering
  work.
- The menubar's Control Center button always shows the Fedora logo
  (`Bar/Modules/Control.qml`), and the drawer shows it on Fedora systems.
- No "not provided or supported by the Fedora Project" notice was found in the
  README, welcome window, or installer.

No trademark registration or clearance search for the CybexOS or Cybex name
and wordmark is recorded. "Cybex" is also used as a brand by unrelated
companies. Bundled vendor applications (Brave, 1Password, ChatGPT, Spotify,
Steam, Firefox and others) carry their owners' marks; whether a third-party ISO
may redistribute them under those marks is **Unverified**.

## Firmware

- `linux-firmware` (`GPL-1.0-or-later AND GPL-2.0-or-later AND MIT AND
  LicenseRef-Fedora-Firmware`) and its split packages (`amd-gpu-firmware`,
  `intel-gpu-firmware`, `nvidia-gpu-firmware`, Wi-Fi, Bluetooth, audio,
  microcode, and the XPS NPU and vision firmware) are bundled from Fedora.
  `LicenseRef-Fedora-Firmware` is Fedora's identifier for firmware it accepts
  as redistributable without modification; its definition was not re-read for
  this audit. `linux-firmware-whence` was in the 2026-09-25 package list.
- `nvidia-gpu-firmware` ships `LICENCE.nvidia`. Its section 2.1.2 allows the
  firmware to be "copied and redistributed solely for use on operating systems
  distributed under the terms of an OSI-approved open source license ...,
  provided that the binary files thereof are not modified, and Customer
  provides a copy of this license with the SOFTWARE."
- The image is composed with `%packages --excludedocs`. RPM normally keeps
  `%license` files with that option, but whether `/usr/share/licenses` is
  complete in the built image is **Unverified**.
- Proprietary NVIDIA drivers are not bundled. On machines with an NVIDIA GPU,
  the `nvidia` hardware role downloads `akmod-nvidia`,
  `xorg-x11-drv-nvidia-cuda-libs` and `libva-nvidia-driver` from RPM Fusion
  nonfree after installation and builds the module locally (see
  [NVIDIA graphics](nvidia.md)), so the user's machine, not the ISO, receives
  NVIDIA's software. Re-audit if the ISO ever composes these packages.

## Codecs and patents

These are patent-licensing questions, separate from copyright. Fedora omits
these codecs from its own media.

- RPM Fusion's `ffmpeg`, `x264-libs`, and `x265-libs` (H.264 and HEVC) and
  `intel-media-driver` are composed into every image. Whether CybexOS may
  distribute them, and from which jurisdiction, needs a legal decision.
- Cisco's [OpenH264 binary license](http://www.openh264.org/BINARY_LICENSE.txt)
  provides patent coverage only when the binary is "separately downloaded to an
  end user's device" and "not integrated into or combined with third party
  software prior to being downloaded". It also requires user control and the
  attribution "OpenH264 Video Codec provided by Cisco Systems, Inc." Composing
  `openh264`, or copying the Flatpak `openh264` extension, into the ISO would
  fall outside that coverage. The installed system's enabled Fedora Cisco
  repository can download it instead.

## Source-code obligations

The ISO distributes GPL, LGPL and AGPL binaries from Fedora, RPM Fusion and the
COPR, plus source-built `awww` (GPL-3.0) and `wayfreeze` (AGPL-3.0), Quickshell
(LGPL-3.0), and Bun's LGPL JavaScriptCore. A distributor of these binaries has
source obligations of its own. The release workflow publishes only the
CybexOS source archive. Whether pointing to upstream sources is sufficient is
for legal review; publishing the corresponding sources for each ISO avoids the
question.

## Blockers before public ISO distribution

1. **Wallpapers.** All seven lack a creator, source, and license, and six
   appear by file name to depict Marvel or DC characters. They are bundled in
   the desktop RPM and ISO, and already published in the repository and
   browser demo.
2. **Bundled proprietary applications.** No redistribution permission was
   located for Spotify, the Android SDK, Claude Code, 1Password, ChatGPT or
   Brave Origin, and the quoted Spotify and Android SDK terms conflict with
   bundling. The Android SDK license is accepted on the user's behalf.
3. **Cisco OpenH264.** If the image composes `openh264` or the Flatpak
   `openh264` extension, Cisco's patent coverage does not apply to those
   copies.
4. **Fedora trademarks.** The image keeps `fedora-release` packages, the shell
   shows the Fedora logo, and the required notice is missing.
5. **Patent-encumbered codecs** from RPM Fusion need a documented legal
   decision.
6. **Corresponding source** for GPL, LGPL and AGPL components is not published
   with the ISO.
7. **OPPO Sans** requires a prominent in-software notice that does not exist.

Items needing confirmation rather than known conflicts: Steam's launcher
redistribution, vendor trademark use, the Flatpak runtime contents, retained
license files under `--excludedocs`, `mdview` and Plymouth artwork licenses,
and per-brand icon guidelines.

## Recommended actions

1. Replace or remove the wallpapers with images whose rights are documented
   (owner-created, CC0, or CC BY with attribution). Record them in
   `assets/PROVENANCE.json` and extend `tests/repository-policy.py` beyond
   `assets/` to cover `web/public` and other raster assets.
2. Stop bundling proprietary applications whose terms do not allow it.
   Download them at first boot or first use from the vendor repositories the
   image already configures with pinned keys, or obtain written permission
   and record it in the repository. Keep the offline payload for software
   whose license allows it.
3. Download the Android SDK at first use and ask the user to accept Google's
   terms, instead of running `yes | sdkmanager --licenses` on both paths.
4. Exclude Cisco's `openh264` and the Flatpak `openh264` extension from the
   image; install them after installation from Cisco's repository.
5. Ship a CybexOS release-identity package in place of `fedora-release*`,
   update the `ID=fedora` checks, replace the Fedora logo in the menubar, and
   add the required Fedora notice to the README, welcome window, and About
   page. Use "Fedora Remix" wording only as the guidelines allow.
6. Generate a license report from each build's package list (name, version,
   repository, License tag), publish it with the release, and fail the build
   on unreviewed proprietary tags or repositories.
7. Publish source RPMs and source archives for every composed package and
   source-built tool with each ISO, or obtain legal advice on an alternative.
8. Add a third-party notices page (for example under Settings → About) that
   includes the OPPO Sans notice, and the OpenH264 attribution if it is used.
9. Source Google Sans Flex from `google/fonts` with its official `OFL.txt`.
   Pin the Codex CLI version and the Voxtype model checksum so each image's
   payload can be reviewed.
10. Add licenses to `DigitalPals/mdview` and `DigitalPals/omarchy-cybex`, and
    record the provenance of the Plymouth artwork and Cybex wordmark.
11. Run a trademark clearance check for CybexOS and Cybex, and review the
    brand guidelines for each product mark in the shell.
12. Have the owner and legal counsel review this list, and record each
    decision here before the first public ISO.

## Not verified

- OpenAI's terms for the ChatGPT desktop application.
- An explicit Valve grant for redistributing the Steam launcher.
- Trademark policies of Brave, 1Password, OpenAI, Spotify, Valve, Mozilla,
  Rust, and each brand in the shell.
- Which OpenH264 provider the current image composes, and the Flatpak runtime
  and extension contents.
- The complete contents and notices of the T3 Code AppImage, balena CLI
  bundle, and Android SDK components that may fall under the SDK's
  open-source exception (section 3.5).
- The license of `DigitalPals/mdview` and of the Plymouth artwork and wordmark.
- Retention of `/usr/share/licenses` in the built image.
- The current revision's payload; no current ISO was built for this audit.
