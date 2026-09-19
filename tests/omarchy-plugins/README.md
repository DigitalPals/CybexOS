# Omarchy compatibility fixtures

Unmodified upstream files:

- `pomodoro/{Panel.qml,manifest.json}`: markbus-ai/omarchy-pomodoro commit
  54dec957244d7090bc1c46be7244f8a60a7f4866, MIT (pomodoro/LICENSE).
- `Spacer.qml`: omacom/omarchy commit
  60663faf8764253646f1d6166e864b608d4a0fa1, MIT (LICENSE.omarchy).
- `media/{manifest.json,Service.qml,BarWidget.qml,MediaModel.js}` and
  `bar/{manifest.json,Bar.qml,BarModel.js}`: the same Omarchy commit and license,
  from `shell/plugins/services/media` and `shell/plugins/bar`.

These files remain byte-for-byte upstream fixtures. `contract/*.qml` and
`shell.qml` are local test harnesses. Tests install disposable packages and
run the actual Quickshell engine on two headless Sway outputs to exercise
lifecycle, settings, shared services and replacement bars. Native widgets,
Pomodoro and Spacer also run through runtime replacement and rollback.

Loading Media without a player/audio session is not an audio playback test.
See docs/omarchy-plugin-compatibility.md for coverage and remaining limits.
