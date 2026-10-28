# Connects the browser to the 1Password desktop app as on a fresh
# installation: the welcome guide's Connect step opens the real 1Password,
# then Brave Origin starts an extension with 1Password's extension id and
# asks for 1Password's native messaging host.
#
# 1Password writes that host only into the browser profiles it knows; Origin
# reads its own profile and Chromium's system directory, where Cybex OS puts
# the same entry. The host must be found, start through the NixOS setgid
# helper, accept Brave Origin's executable and reach the running app, and the
# entry must match the one this 1Password writes for its own browsers.
#
# The guide's 1Password card counts the accounts in 1Password's own database:
# there are none before a sign-in, so it shows no tick. With 1Password
# stopped, the check then adds an account row, and the card must show one.
#
# Leaving the guide then closes what Connect opened: a 1Password window left
# open, and the assistant sign-in's terminal and the Brave window it opened,
# while a window the person opened stays. The guide stays up until they are
# gone.
#
# Test-only settings: SDDM signs the user in directly, Brave does not fetch
# the store extension (the VM has no network), and the probe carries the
# store extension's public key, which gives an unpacked extension the same
# id. 1Password is not signed in, and its main window does not draw in this
# VM; the browser link needs neither, and a window of its class stands in
# for it.
# Claude Code is a script that opens its sign-in page with xdg-open, as the
# real one does, and is signed in once the check says so. The added row is
# not a real account. This is VM qualification of the browser link and of
# the guide's reading of the database, not of a 1Password account, of
# autofill or of a Claude sign-in.
{ pkgs, module }:
let
  # The `key` of 1Password's Chrome Web Store manifest: its public key, whose
  # hash is the id aeblfdkhhhdcdjpifhhbdiojplfjncoa.
  key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnHpaUll4uWujpAdbIXOQY2WE6hk8PllsYsnoUaj5qHXwv4IB6A9pONqGaTL2KL20u6E6XVhncY6Ae6SQSBQqiIkgjPsiG0NDNsDlju/kzBnfimKFC/bpzOrqFqbhswQHifnet5uHlpG97whTzLO3ka0M5aqB9V9mD/0qVXvNgAVVnSTULH254YqpeCcAhmsKiFZSL6OrOZmCp8kZ/OeOUK9iYWYylL7VcOXVrZf10EPrlaCNXzVk7K35dPuQ7svhA0Pgju3kngB4RLa5Iojhw3IT+B5+m8pisjOSd1oKMrRmhGs7rDhF5IEtAiVxqVp7uOOMPQj3vrbMDAzf7vqLtQIDAQAB";
  probe = pkgs.linkFarm "cybexos-1password-probe" {
    "manifest.json" = pkgs.writeText "manifest.json" (builtins.toJSON {
      manifest_version = 3;
      name = "Cybex OS 1Password probe";
      version = "1";
      inherit key;
      permissions = [ "nativeMessaging" ];
      background.service_worker = "probe.js";
    });
    # Holds the host open as the extension does, and reports whether it stayed.
    "probe.js" = pkgs.writeText "probe.js" ''
      const port = chrome.runtime.connectNative("com.1password.1password");
      let open = true;
      port.onDisconnect.addListener(() => {
        open = false;
        console.log("CXO-PROBE closed: " + (chrome.runtime.lastError && chrome.runtime.lastError.message));
      });
      setTimeout(() => { if (open) console.log("CXO-PROBE open"); }, 8000);
    '';
  };
  launchBrave = pkgs.writeShellScript "cybexos-1password-brave" ''
    exec brave --no-first-run --disable-features=DisableLoadExtensionCommandLineSwitch \
      --load-extension=${probe} --enable-logging=stderr about:blank > /home/tester/brave.log 2>&1
  '';
  # A row in 1Password's own accounts table; its data is not a real account.
  addAccount = pkgs.writeText "cybexos-1password-account.py" ''
    import sqlite3
    db = sqlite3.connect("/home/tester/.config/1Password/1password.sqlite")
    db.execute("INSERT INTO accounts VALUES (?, ?)", ("cybexos-test", b"{}"))
    db.commit()
  '';
  # Claude Code's sign-in as the guide runs it: its page opens in the default
  # browser, and the person finishing it there is the check's approval.
  claude = pkgs.writeShellScript "cybexos-claude-sign-in" ''
    state=/home/tester/claude-sign-in
    case "$*" in
      "auth status") test -e "$state/signed-in" ;;
      "auth login")
        mkdir -p "$state"
        # Detached, as Claude Code starts it.
        setsid -f xdg-open "https://claude.ai/oauth/authorize?code=true" >/dev/null 2>&1
        until test -e "$state/approved"; do sleep 0.2; done
        touch "$state/signed-in"
        echo "Login successful." ;;
      *) exit 2 ;;
    esac
  '';
  # A window of 1Password's class, closing at once as its own does.
  passwordWindow = pkgs.writeShellScript "cybexos-1password-window" ''
    exec ${pkgs.kitty}/bin/kitty -o confirm_os_window_close=0 --class 1Password ${pkgs.coreutils}/bin/sleep 1777
  '';
  ownWindow = pkgs.writeShellScript "cybexos-own-window" ''
    exec ${pkgs.kitty}/bin/kitty --class cxo-own ${pkgs.coreutils}/bin/sleep 1555
  '';
in pkgs.testers.runNixOSTest {
  name = "cybexos-browser-1password";
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = true; steam = false; docker = false; }; };
    # The probe takes the store extension's id; the VM cannot fetch that one.
    cybexos.browser.bravePolicies.ExtensionInstallForcelist = lib.mkForce [ ];
    systemd.user.services.cybexos-assistant.environment.CYBEXOS_ASSISTANT_CLAUDE = "${claude}";
    networking.hostName = "machine";
    users.users.tester.initialPassword = "qualification-only";
    services.displayManager.autoLogin = { enable = true; user = "tester"; };
    virtualisation = {
      memorySize = 8192;
      cores = 8;
      graphics = true;
      diskSize = 4096;
      qemu.options = [ "-no-user-config" "-device virtio-vga,xres=1280,yres=800" ];
    };
    system.stateVersion = "26.05";
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
  testScript = ''
    import json

    HOST = "com.1password.1password.json"
    LOGS = "/home/tester/.config/1Password/logs"

    machine.start()
    machine.wait_for_unit("display-manager.service")
    uid = machine.succeed("id -u tester").strip()
    session = f"XDG_RUNTIME_DIR=/run/user/{uid} HOME=/home/tester DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"

    def user(command):
        return machine.succeed(f"runuser -u tester -- env {session} {command}")

    def welcome():
        return json.loads(user("cybexos-runtime ipc welcome status"))

    def clients():
        return {c["address"].removeprefix("0x"): c["class"] for c in json.loads(user("hyprctl -i 0 -j clients"))}

    def layers():
        return {layer.get("namespace") for monitor in json.loads(user("hyprctl -i 0 -j layers")).values()
                for level in monitor.get("levels", {}).values() for layer in level}

    def kinds(addresses, windows):
        """Window classes, with Brave's (which its launcher decides) as "brave"."""
        return sorted("brave" if "brave" in windows[a].lower() else windows[a] for a in addresses)

    def classes():
        windows = clients()
        return set(kinds(windows, windows))

    def run(script):
        user(f"hyprctl -i 0 dispatch 'hl.dsp.exec_cmd(\"{script}\")'")

    def host(path):
        entry = json.loads(machine.succeed(f"cat {path}"))
        return {**entry, "allowed_origins": sorted(entry["allowed_origins"])}

    machine.wait_until_succeeds(f"runuser -u tester -- env {session} systemctl --user is-active quickshell.service", timeout=600)
    machine.wait_until_succeeds(f"runuser -u tester -- env {session} cybexos-runtime ipc welcome status", timeout=300)

    # The guide's Connect step opens 1Password from its desktop entry.
    assert user("cybexos-runtime ipc welcome open connect").strip() == "ok"
    assert user("cybexos-runtime ipc welcome connect password").strip() == "ok"
    machine.wait_until_succeeds(f"grep -q 'Starting IPC listener on 1Password-BrowserSupport' {LOGS}/1Password_rCURRENT.log", timeout=180)

    # 1Password's own entries leave Origin's profile out; the system one is the same entry.
    machine.succeed(f"test -f /home/tester/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/{HOST}")
    machine.fail(f"test -e /home/tester/.config/BraveSoftware/Brave-Origin/NativeMessagingHosts/{HOST}")
    ours = host(f"/etc/chromium/native-messaging-hosts/{HOST}")
    theirs = host(f"/home/tester/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/{HOST}")
    assert ours == theirs, (ours, theirs)
    machine.succeed("test -g /run/wrappers/bin/1Password-BrowserSupport")

    # Brave Origin finds the host, 1Password accepts the browser, and the app answers.
    user("hyprctl -i 0 dispatch 'hl.dsp.exec_cmd(\"${launchBrave}\")'")
    machine.wait_until_succeeds("grep -q CXO-PROBE /home/tester/brave.log", timeout=180)
    probe = machine.succeed("grep CXO-PROBE /home/tester/brave.log")
    assert "CXO-PROBE open" in probe, probe
    # The kernel shortens the helper's command name, so match its arguments.
    helper = machine.succeed("ps -eo egid=,args= | grep '[1]Password-BrowserSupport chrome-extension'")
    assert "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/" in helper, helper
    assert helper.split()[0] == machine.succeed("getent group onepassword | cut -d: -f3").strip(), helper
    support = machine.succeed(f"cat {LOGS}/BrowserSupport/1Password_rCURRENT.log")
    assert "brave-origin" in support and "verified successfully" in support, support
    assert "Connected to the desktop app" in support, support
    machine.succeed(f"grep -q 'Extension connecting' {LOGS}/1Password_rCURRENT.log")
    machine.screenshot("brave")
    machine.succeed("pkill -u tester -x brave")

    # This 1Password's database, with no account yet: the card has no tick.
    assert welcome()["connect"]["password"] == "opened", welcome()
    machine.succeed("pkill -u tester -x 1password")
    machine.wait_until_fails("pgrep -u tester -x 1password", timeout=60)
    user("${pkgs.python3.interpreter} ${addAccount}")
    assert user("cybexos-runtime ipc welcome open connect").strip() == "ok"
    retry(lambda _: welcome()["connect"]["password"] == "ready", timeout_seconds=30)
    machine.screenshot("connect-signed-in")

    # 1Password again, left open: the person resumes from the pill instead.
    assert user("cybexos-runtime ipc welcome connect password").strip() == "ok"
    run("${passwordWindow}")
    retry(lambda _: "1Password" in classes(), timeout_seconds=60)
    assert user("cybexos-runtime ipc welcome open connect").strip() == "ok"
    retry(lambda _: not welcome()["aside"], timeout_seconds=15)
    # A window the person opens while the guide shows is theirs.
    run("${ownWindow}")
    retry(lambda _: "cxo-own" in classes(), timeout_seconds=60)
    assert user("cybexos-runtime ipc welcome open connect").strip() == "ok"
    retry(lambda _: not welcome()["aside"], timeout_seconds=15)

    # The sign-in opens the default terminal and, from there, Brave Origin.
    retry(lambda _: user("cybexos-runtime ipc welcome connect claude").strip() == "ok", timeout_seconds=60)
    retry(lambda _: {"kitty", "brave"} <= classes(), timeout_seconds=120)
    assert welcome()["aside"] and welcome()["connect"]["assistant"] == "signing-in", welcome()
    machine.screenshot("sign-in")
    user("touch /home/tester/claude-sign-in/approved")
    retry(lambda _: not welcome()["aside"] and welcome()["connect"]["assistant"] == "ready", timeout_seconds=60)
    opened = welcome()["connectWindows"]
    windows = clients()
    machine.log("windows: " + json.dumps(windows) + ", the guide's: " + json.dumps(opened))
    # The real 1Password may show a window too: here, under its Wayland app
    # id, the dialog saying the made-up account stops it from starting. The
    # keyring prompt Brave raises is this VM's: its sign-in leaves the
    # keyring locked.
    assert {"1Password", "brave", "kitty"} <= set(kinds(opened, windows)) \
        <= {"1Password", "1password", "brave", "kitty", "gcr-prompter"}, (opened, windows)

    # Leaving closes them before the desktop shows; the person's own stays.
    user("cybexos-runtime ipc welcome close")
    retry(lambda _: not layers() & {"qs-welcome", "qs-welcome-resume"}, timeout_seconds=30)
    windows = clients()
    assert not set(opened) & set(windows), (opened, windows)
    assert "cxo-own" in windows.values(), windows
    machine.screenshot("desktop")
  '';
}
