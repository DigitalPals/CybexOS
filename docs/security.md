# Fingerprints and security keys

CybexOS accepts a fingerprint or a FIDO2/U2F security key as an alternative to
the password for the **lock screen**, **sudo** and **system prompts** (the
shell's Polkit dialog). The password always keeps working. Signing in at the
login screen after a restart always asks for the password.

Manage both in **Settings > Security** (`cybexos-runtime ipc settings open
security`). The page has two groups:

- **Fingerprint**: the reader, the enrolled fingers, **Add fingerprint** (choose
  a finger, then scan it until the bar fills), **Remove…** with a confirmation,
  and **Use fingerprint to unlock and authorise** once a finger is enrolled.
- **Security keys**: the registered keys, **Add security key** (touch the key
  when it flashes) and **Remove…** with a confirmation.

Without a reader, or without key support, each group shows one short line
instead of controls.

## Installation

Every installation, on any hardware, gets the same packages and policy; the
checkout (`./install`, `./bootstrap`) and the ISO apply them identically.

| Part | Source | Checkout | ISO |
| --- | --- | --- | --- |
| `fprintd`, `fprintd-pam`, `libfprint`, `pam-u2f`, `pamu2fcfg`, `libfido2` | `base_required_packages` | base role | compose; `cybexos-desktop` `Requires` for upgrades |
| `authselect` feature `with-fingerprint` | `cybexos-auth-policy apply` | base role | kickstart selection, then the same helper during installation, repair and reconciliation |
| Security-key steps and `/etc/pam.d/cybexos-lock` | `cybexos-auth-policy apply` | base role | the same helper |
| Settings switch helper | `roles/base/files/cybexos-auth-policy` | `/usr/local/libexec/` | `/usr/libexec/` |

`roles/base/tasks/authentication.yml` runs the helper from the role in
workstation convergence (`main.yml`), ISO installation and repair
(`image.yml`) and upgrade reconciliation (`reconcile.yml`). A failure is
reported and leaves the password unchanged; it does not stop the install.

The XPS 2026 role keeps only its hardware-specific part: the detector that
rejects the IPU7 camera's USB bridge, the `xps-fingerprint-check` diagnostic,
and a report when the detected reader is not one libfprint supports. See
[Dell XPS 2026 hardware support](xps-2026-hardware.md).

## PAM design

The rule throughout: every addition is `sufficient` and sits in front of an
otherwise unchanged stack, so a missing reader, finger, key, module or daemon
falls through to the password. Nothing removes or reorders `pam_unix`.

### Fingerprints

Fedora's managed `authselect` feature `with-fingerprint` adds
`auth sufficient pam_fprintd.so` to `system-auth`. That stack serves sudo,
Polkit, `su` and console login. It is not added to `password-auth`, which
serves SDDM. `pam_fprintd` returns at once when fprintd has no device or the
person has no enrolled finger, so they are asked for the password as before.

CybexOS enables the feature once (recorded in
`/var/lib/cybexos/authentication/fingerprint-adopted`). After that,
`authselect`'s own state is the person's choice: the Settings switch runs
`pkexec cybexos-auth-policy fingerprint on|off`, which calls
`authselect enable-feature`/`disable-feature`, and no later install, repair or
upgrade turns it back on. The switch applies to every account on the computer.
If authselect does not manage the system, CybexOS leaves fingerprint sign-in
alone and the switch reads *Managed outside CybexOS*.

### Security keys

pam_u2f is added as the first `auth` step of exactly three stacks:
`/etc/pam.d/sudo` (and therefore `sudo-i`), `/etc/pam.d/polkit-1` (Polkit's
vendor stack from `/usr/lib/pam.d/polkit-1`, regenerated on each run so a Polkit
update is followed) and the lock screen's `/etc/pam.d/cybexos-lock`:

```text
-auth sufficient pam_u2f.so cue nouserok userpresence=1 origin=pam://cybexos appid=pam://cybexos authfile=.config/Yubico/u2f_keys [cue_prompt=Touch your security key]
```

- `nouserok`: an account without registered keys is unaffected (pam-u2f 1.4
  returns `PAM_IGNORE` for it).
- `userpresence=1`: a touch is always required.
- `origin`/`appid` `pam://cybexos`: fixed, so renaming the computer does not
  invalidate keys (pam_u2f's default is `pam://$HOSTNAME`).
- `authfile=.config/Yubico/u2f_keys`: relative to the account's home and opened
  as that account, never by root through a path the person controls.
- `-auth`: if the module is missing the line is skipped, not an error.

authselect's own `with-pam-u2f` feature is deliberately not used: it would put
the key step into `password-auth` as well, where a touch at the SDDM login
would sign in without the password that unlocks GNOME Keyring.

The helper leaves an administrator's own configuration alone. A file that
already contains a `pam_u2f` line (for example a required second factor) gains
no CybexOS step, an administrator's own `/etc/pam.d/polkit-1` gains only the
key line, and a `cybexos-lock` without the CybexOS header is never rewritten. If authselect's `with-pam-u2f` or
`with-pam-u2f-2fa` is enabled, CybexOS removes its own key steps and Settings
reports that keys are managed with authselect.

Registrations live in `~/.config/Yubico/u2f_keys` (folder `0700`, file `0600`,
SELinux label restored after each change). Settings runs
`pamu2fcfg -n -o pam://cybexos -i pam://cybexos` and appends the result. A key
that asks for its PIN to register cannot be added from Settings, which has no
terminal for the PIN prompt; register it in a terminal instead:

```bash
mkdir -p -m 0700 ~/.config/Yubico
pamu2fcfg -o pam://cybexos -i pam://cybexos >>~/.config/Yubico/u2f_keys   # first key
pamu2fcfg -n -o pam://cybexos -i pam://cybexos >>~/.config/Yubico/u2f_keys # further keys
chmod 0600 ~/.config/Yubico/u2f_keys
```

Keys registered with another origin (for example pamu2fcfg's default) do not
verify with the CybexOS steps.

### Login (SDDM): password only

SDDM's stack includes `password-auth`, which has neither `pam_fprintd` nor
`pam_u2f`. This is intentional. The login password is what unlocks GNOME
Keyring: on an encrypted installation with automatic login, the LUKS
passphrase cached by `pam_systemd_loadkey` does it (the `sddm-autologin` stack
is unchanged); otherwise `pam_gnome_keyring` uses the password typed into SDDM.
A fingerprint or key login would leave the keyring locked until the first
application asked for it. After the first login, the lock screen, sudo and
Polkit accept fingerprints and keys.

### Lock screen (hyprlock)

`pam_fprintd` cannot run beside the password in one PAM conversation: the stack
is sequential, and while it waits for a finger the password cannot be checked.
hyprlock therefore uses its own fprintd D-Bus check, which runs in parallel
with PAM, and a PAM service without `pam_fprintd`:

```text
# /etc/pam.d/cybexos-lock
-auth      sufficient   pam_u2f.so …
auth       include      password-auth
```

`cybexos-runtime exec hyprlock` adds the authentication to the vendor or themed
lock screen at each lock (written to `$XDG_RUNTIME_DIR/cybexos/hyprlock.conf`):

- `auth:pam:module = cybexos-lock`, only when that file exists. Without it the
  configuration is used as is: naming a missing PAM service would refuse every
  password.
- `auth:fingerprint:enabled` follows `with-fingerprint` in
  `/etc/authselect/authselect.conf`, with the prompt *Touch the fingerprint
  reader or enter your password* shown under the field (`$FPRINTPROMPT`). With
  no reader or no enrolled finger the prompt stays empty.
- When the account has a registered key, the field reads *Password or security
  key*, an empty Enter is passed to PAM, and while PAM waits for the touch the
  field shows *Touch your security key if it flashes*. hyprlock starts PAM only
  when the field is submitted and does not display PAM's own cue.

A person's own `~/.config/cybexos/hypr/hyprlock.conf` is used unchanged; add an
`auth` section to it to use these factors.

### Sudo and Polkit prompts

These stacks are sequential: with a registered key plugged in, pam_u2f waits
for its touch first; with an enrolled finger, `pam_fprintd` waits for a finger
(up to 30 seconds and three attempts); then the password is asked. The shell's
Polkit dialog recognises both steps from PAM's messages and says *Touch the
fingerprint reader, or wait to enter your password.* or *Touch your security
key, or wait to enter your password.* instead of showing a password field that
cannot take input yet. A mismatched scan adds *Not recognised.* In a terminal,
sudo prints PAM's own messages.

## Recovery

Nothing here can lock anyone out: the password is accepted by every stack.
If a reader misbehaves, turn the Settings switch off, or run
`sudo authselect disable-feature with-fingerprint`. Remove a misbehaving key's
line from `~/.config/Yubico/u2f_keys`, or delete the file. `cybex uninstall`
runs `cybexos-auth-policy remove`, which removes the CybexOS key steps and lock
service and leaves authselect's fingerprint feature as chosen.

## Manual verification on real hardware

The repository tests stub authselect, fprintd and pamu2fcfg, and a Fedora 44
container checked the generated stacks with `pamtester` (password accepted and
rejected correctly for sudo, `sudo-i`, Polkit and `cybexos-lock`, with and
without a registered but absent key, and with fprintd unavailable). The
following still needs a person, a reader and a key:

1. A machine without a reader: Settings > Security shows *No fingerprint reader
   was found.*; sudo and Polkit ask for the password with no delay.
2. Enrol a finger from Settings: the Polkit dialog asks for the password first
   (fprintd's enrol action), the counter and bar advance with each scan, retry
   messages appear for a short or off-centre scan, and the finger is listed.
   Cancel an enrolment midway and confirm the reader is released (a second
   enrolment starts).
3. Remove a finger; Polkit asks again; the list updates.
4. Lock the screen: the prompt appears under the field, a finger unlocks, a
   wrong finger shows the failure, and typing the password still unlocks at
   once while the reader is idle. Suspend and resume while locked.
5. sudo in a terminal and a Polkit action (for example a timezone change): the
   finger works; ignoring the reader leads to the password prompt after the
   timeout; the dialog's wording is as above.
6. Turn the switch off: the lock screen shows no prompt, sudo asks for the
   password at once; `cybex update` does not turn it back on.
7. Register a key from Settings (with and without the key inserted beforehand;
   a key with a PIN shows the terminal hint). Then: lock screen (Enter, then
   touch), sudo, Polkit, and the same with the key unplugged (password only, no
   delay). Rename the computer and confirm the key still works.
8. Restart: SDDM asks for the password; the keyring is unlocked (for example
   in a browser that stores passwords). With encrypted automatic login, the
   desktop starts and the keyring is unlocked as before.
9. On an XPS 2026 with a supported reader, `xps-fingerprint-check "$USER"`
   passes; on the tested SKU `0DB9`, the SVP7500 camera bridge is still not
   reported as a reader.
