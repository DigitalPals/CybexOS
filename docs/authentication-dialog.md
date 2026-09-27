# Authentication dialog

CybexOS handles Polkit requests in the managed Quickshell process. The built-in
`PolkitWindow.qml` owns one `Quickshell.Services.Polkit.PolkitAgent`, including
when a plugin replaces the bar. `PolkitPrompt.qml` presents its current flow.
Polkit and the system's PAM configuration still decide which identities may
authenticate and whether their responses succeed; the shell changes no policy.

The compact card uses `Common/Theme.qml` fonts, density, light/dark colors and
wallpaper palette. It opens on the focused monitor and stays there until the
request ends, with a fallback if that output disappears. Account names wrap,
multiple eligible identities get a selector, and the action ID is available
under Show details. The card scrolls on small outputs or with large text.

Enter submits the current response, Escape or Cancel aborts the request, and
Tab reaches the controls. Clicking the dimmed background does not dismiss it.
The launcher, drawers and shortcut sheet close during authentication so they
cannot take the password field's keyboard focus. The Network overlay temporarily
hides and releases its focus grab while keeping its requesting helper alive;
it returns when the authentication flow ends. A normal settings window can
remain open behind a request it initiated.

Passwords start masked, never echo the last character, and can be revealed
with the eye button. PAM prompts that request visible responses are supported,
as are informational messages while waiting for fingerprint or other methods.
The response is cleared on submission, cancellation, account/prompt changes,
completion and replacement by another request. Closing the window destroys
the input. Responses go directly to the backend; no shell command, IPC method,
log or persistent setting carries them. This does not promise secure erasure
of Qt's or the authentication library's internal memory.

## Startup and rollback

`cybexos-runtime exec quickshell` stops a loaded or active
`hyprpolkitagent.service` before registering the integrated agent. Source
deployment removes the old session enablement and managed unit; new images
neither require nor start the standalone agent. Existing RPMs are left
installed. Selecting an older runtime without `PolkitWindow.qml` starts the
legacy agent when its unit is available, including after a deployment rollback.

`cybexos-runtime ipc polkit status` returns only `registered` and `active`.
There is no diagnostic method to read or submit a response. Registration must
be true before considering a deployment healthy. After switching from an old
installed runtime resolver to development source, use the checkout's resolver
for the managed service too, or stop the old agent before restarting Quickshell.
Do not start a second `qs` instance to test a dialog.

## Verification

`tests/run` checks account-label handling, QML, startup integration and icon
coverage. `tests/ownership-layering.py` verifies the agent transition and legacy
fallback with isolated service/executable fixtures. The production-component
lifecycle harness exercises submission, duplicate-submit prevention, retry,
account switching, visible PAM responses, local/remote cancellation, completion
and clearing state between requests. Its Polkit fixture never authenticates
against the host. The real-engine harness runs in CI without an active shell;
on a workstation use `tests/lib/quickshell-live` before and after any controlled
test that stops and restores the service.

For live acceptance, verify registration, trigger a real Polkit authorization
check, cancel with the keyboard and confirm the requesting process is denied.
Also check details expansion, password visibility, Tab order, background clicks,
blocked competing overlays, large text, both color modes and output removal.
Successful authentication and fingerprint/other PAM methods require an operator
with the relevant credential or hardware; never collect their password through
agent tools.

On 2026-09-26 the installed Quickshell 0.2.1 build registered successfully and
displayed a real `com.1password.1Password.unlock` authorization check. Escape
returned a dismissed result to `pkcheck`; Tab navigation, visibility, details
and blocking the competing launcher were exercised. The isolated real-engine
conversation fixture and the image's 29 installed-policy/user-parity tests
passed. The managed service finished as the sole `qs` process, with no QML
errors in its current invocation and the old agent inactive. Successful real
authentication, fingerprint hardware and monitor removal were not exercised.
