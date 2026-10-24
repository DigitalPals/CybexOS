# Quickshell icon assets

The shell chooses icons by semantic role:

- Generic actions and status use `Common/Sym.qml` and bundled Tabler icons.
  See [tabler/README.md](tabler/README.md) for the pinned fonts, name mapping
  and regeneration instructions.
- Product identities use `Common/BrandIcon.qml` and the allow-list in
  `Common/BrandIcons.qml`.
- Installed applications use the desktop icon theme through
  `Quickshell.iconPath()`; tray items retain the status-notifier icon supplied
  by their application.
- Small animated primitives may be drawn in QML when an icon-font shape does
  not animate or align correctly.

Do not add an identity SVG directly to a view. Add its canonical asset here,
record its provenance below, register it in `BrandIcons`, and render it through
`BrandIcon`. Small interactive marks also get a `-white.svg` sibling made by
changing paint only. `BrandIcon` cross-fades those two source files so hover
does not rebuild the mark from an alpha mask and change its apparent weight.
T3's canonical mark is already white and is reused for both states.

## Provenance

The source revisions are pinned so each path can be audited independently of
later upstream changes. Local changes are limited to adding a shell palette
fill, removing redundant SVG metadata, or cropping a mark out of its app-icon
background.

| Assets | Vector source | Revision | Local treatment |
| --- | --- | --- | --- |
| `claude.svg`, `gemini.svg` (`googlegemini`), `github.svg`, `kimi.svg`, `tailscale.svg`, `whatsapp.svg`, `youtube.svg` and their `-white.svg` siblings | [Simple Icons](https://github.com/simple-icons/simple-icons) | `4a79bb55697c85b8bc9f3caa22be747e0277ad4f` | Upstream paths with product/shell paint; hover siblings change only that paint. |
| `openai.svg`, `openai-white.svg` | [Tabler Icons: `brand-openai`](https://github.com/tabler/tabler-icons/blob/5a0fe38e97784d94279ce4eb1bf85f9a91bf027e/icons/outline/brand-openai.svg) | `5a0fe38e97784d94279ce4eb1bf85f9a91bf027e` | Upstream strokes with Codex/white paint. Stroke width and geometry are unchanged. |
| `slack.svg`, `slack-white.svg` | [Tabler Icons: `brand-slack`](https://github.com/tabler/tabler-icons/blob/5a0fe38e97784d94279ce4eb1bf85f9a91bf027e/icons/outline/brand-slack.svg) | `5a0fe38e97784d94279ce4eb1bf85f9a91bf027e` | Upstream strokes with Slack red/white paint. Stroke width and geometry are unchanged. |
| `grok.svg`, `grok-white.svg` | [CLI Proxy API Management Center: `grok.svg`](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/blob/382c09109db2e70a6e60697c0ae0cf6ef97198e7/src/assets/icons/grok.svg) | `382c09109db2e70a6e60697c0ae0cf6ef97198e7` | Upstream Grok path with shell-silver/white paint; redundant sizing and inline-style metadata removed. |
| `t3.svg` | [T3 Code production logo](https://github.com/pingdotgg/t3code/blob/a3a8cbd60539b4af4de8f96c892dbd07a2b6c041/assets/prod/logo.svg) | `a3a8cbd60539b4af4de8f96c892dbd07a2b6c041` | Cropped to the wordmark; background removed. |
| `fusebox.svg`, `fusebox-white.svg` | [Fusebox: `assets/icon.svg`](https://github.com/DigitalPals/Fusebox/blob/11fb076e73a96684109cba3b8aa884712846a288/assets/icon.svg) | `11fb076e73a96684109cba3b8aa884712846a288` | Upstream paths and paint; size attributes removed. The hover sibling changes both paints to white. |
| `cybexos.svg`, `cybexos-white.svg` | Owner-supplied `assets/brand/source/cybex_white.svg` | October 2026 | X paths from the supplied wordmark; off-white and white lettering with the original red accent and identical geometry. See `assets/brand/USAGE.md`. |

Simple Icons is distributed under CC0 1.0 and Fusebox under the Unlicense.
Tabler Icons, T3 Code, and the CLI Proxy API Management Center are MIT licensed. The Cybex OS marks are original project artwork under the repository MIT license.
Notices and modification details are retained in `THIRD_PARTY_LICENSES.md`.
Names and logos remain trademarks of their respective owners regardless of
the vector files' copyright licences.
