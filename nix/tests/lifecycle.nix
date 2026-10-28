{ pkgs, module, inputSources, candidate }:
let
  passwordSink = pkgs.writeShellScript "cybexos-plymouth-answer" ''
    ${pkgs.coreutils}/bin/cat > /run/cybexos-plymouth-answer
  '';
  sourceLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  upstream = sourceLock.nodes.${sourceLock.nodes.${sourceLock.root}.inputs.nixpkgs};
  initialLock = pkgs.writeText "cybexos-preview-lock.json" (builtins.toJSON {
    version = 7; root = "root";
    nodes = { root.inputs.nixpkgs = "nixpkgs"; nixpkgs = upstream; };
  });
  previewFlake = pkgs.writeText "cybexos-preview-flake.nix" ''
    {
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
      inputs.cybexos.url = "path:${../..}";
      inputs.cybexos.inputs.nixpkgs.follows = "nixpkgs";
      outputs = { nixpkgs, cybexos, ... }: {
        nixosConfigurations.cybexos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ cybexos.nixosModules.default ./local ];
        };
      };
    }
  '';
  previewLocal = pkgs.writeText "cybexos-preview-local.nix" ''
    { imports = [ ./configuration.nix ./software.nix ./maintenance.nix ]; }
  '';
  interruptedBuild = pkgs.writeText "cybexos-interrupted-build.nix" ''
    { pkgs, ... }: {
      environment.systemPackages = [ (pkgs.runCommand "cybexos-update-interruption" {} "sleep 300; touch $out") ];
    }
  '';
  invalidConfiguration = pkgs.writeText "cybexos-verifier-invalid.lua" ''
  dofile("/etc/cybexos/runtime/hypr/hyprland.lua")
  hl.config({ general = { qualification_invalid_option = 1 } })
'';
in pkgs.testers.runNixOSTest {
  name = "cybexos-lifecycle";
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
    virtualisation = { memorySize = 4096; cores = 4; graphics = true; diskSize = 4096; };
    networking.hostName = "machine";
    users.users.tester.initialPassword = "qualification-only";
    # Retain the complete candidate and its exact input sources. Staging must
    # use the real Nix/updater path without requiring external delivery in a VM.
    system.extraDependencies = inputSources ++ [ candidate previewFlake initialLock pkgs.hello pkgs.sshpass ];
    system.stateVersion = "26.05";
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
  testScript = ''
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("display-manager.service")
    # Fresh connections use Google, with one resolver shared by NM and VPNs.
    # The editable profile must survive restarts and retain an Automatic choice.
    machine.wait_for_unit("cybexos-network-defaults.service")
    machine.wait_for_unit("systemd-resolved.service")
    assert machine.succeed("readlink -f /etc/resolv.conf").strip().endswith("stub-resolv.conf")
    assert machine.succeed("nmcli --escape no -g ipv4.dns connection show 'Cybex OS Wired'").strip() == "8.8.8.8,8.8.4.4"
    assert machine.succeed("nmcli --escape no -g ipv6.dns connection show 'Cybex OS Wired'").strip() == "2001:4860:4860::8888,2001:4860:4860::8844"
    assert json.loads(machine.succeed("tailscale status --json"))["BackendState"] == "NeedsLogin"
    helper = "/etc/cybexos/runtime/quickshell/scripts/network-tool.py"
    machine.succeed("printf '%s\\n' '{\"provider\":\"Automatic\"}' | python3 " + helper + " dns")
    profile_before = machine.succeed("sha256sum /etc/NetworkManager/system-connections/cybexos-wired.nmconnection")
    machine.succeed("systemctl restart cybexos-network-defaults.service NetworkManager.service")
    assert machine.succeed("sha256sum /etc/NetworkManager/system-connections/cybexos-wired.nmconnection") == profile_before
    assert machine.succeed("nmcli -g ipv4.ignore-auto-dns connection show 'Cybex OS Wired'").strip() == "no"
    assert not machine.succeed("nmcli -g ipv4.dns connection show 'Cybex OS Wired'").strip()
    # Even without its marker the initializer preserves existing profiles.
    machine.succeed("rm /var/lib/cybexos-network/defaults-initialized; systemctl restart cybexos-network-defaults.service")
    assert machine.succeed("sha256sum /etc/NetworkManager/system-connections/cybexos-wired.nmconnection") == profile_before
    machine.succeed("printf '%s\\n' '{\"provider\":\"Google\"}' | python3 " + helper + " dns")
    # Recovery is intentionally ordered after these services. Waiting only
    # for multi-user.target can observe it before the first worker invocation.
    machine.wait_until_succeeds("test -n \"$(systemctl show cybexos-recover.service -p ExecMainExitTimestamp --value)\"")
    machine.succeed("test \"$(systemctl show cybexos-recover.service -p Result --value)\" = success")
    machine.succeed("test \"$(systemctl show cybexos-recover.service -p ExecMainStatus --value)\" = 0")
    machine.succeed("systemctl is-active cybexos-recover.service")
    recovery_invocation = machine.succeed("systemctl show cybexos-recover.service -p InvocationID --value").strip()
    # switch-to-configuration starts active targets again while the applying
    # worker owns this lock. Boot recovery must stay completed for this boot,
    # rather than being reentered and poisoning the activation transaction.
    machine.succeed("flock /var/lib/cybexos/operation.lock systemctl start multi-user.target")
    assert machine.succeed("systemctl show cybexos-recover.service -p InvocationID --value").strip() == recovery_invocation
    machine.succeed("systemctl is-active cybexos-recover.service")
    machine.fail("journalctl -b --no-pager | grep -Ei 'cybexos-recover.*(ordering cycle|deleted.*job)|ordering cycle.*cybexos-recover'")
    machine.succeed("cybex update status | grep idle")
    # Software Update reads exact component versions from the system itself.
    components = json.loads(machine.succeed("cat /etc/cybexos/components.json"))["components"]
    assert {"cybexos", "nixos", "kernel", "graphics", "firmware", "hyprland"} <= set(components), components
    assert machine.succeed("uname -r").strip().startswith(components["kernel"]), components
    assert components["nixos"] == machine.succeed("nixos-version").strip().split(" ")[0], components
    # Background preparation and restart confirmation: default policy, fixed
    # units and a timer. Only an active local administrator session may start
    # the units without authentication; this inactive runuser session may not.
    assert json.loads(machine.succeed("runuser -u tester -- cybex update status"))["automatic"] == {"prepare": True, "confirm": True}
    machine.succeed("systemctl is-active cybexos-update-auto.timer")
    machine.succeed("grep -l 'cybexos-update-confirm.service' /etc/polkit-1/rules.d/*.rules")
    machine.fail("runuser -u tester -- systemctl --no-ask-password start cybexos-update-auto.service")
    machine.succeed("cybex update automatic prepare off")
    assert json.loads(machine.succeed("runuser -u tester -- cybex update status"))["automatic"] == {"prepare": False, "confirm": True}
    machine.succeed("test \"$(stat -c %a /var/lib/cybexos/update-automatic.json)\" = 644")
    machine.succeed("systemctl start cybexos-update-auto.service")
    machine.succeed("journalctl -u cybexos-update-auto.service --no-pager | grep -F '\"skipped\": \"disabled\"'")
    machine.succeed("cybex update automatic prepare on")
    machine.succeed("systemctl start cybexos-update-confirm.service")
    machine.succeed("journalctl -u cybexos-update-confirm.service --no-pager | grep -F '\"skipped\": \"idle\"'")
    machine.succeed("test ! -e /var/lib/cybexos/update-request.json")
    assert json.loads(machine.succeed("cat /etc/cybexos/maintenance.json")) == {"automatic": True, "keepConfirmed": 5, "keepDays": 30}
    machine.succeed("systemctl is-active cybexos-maintenance-auto.timer")
    machine.succeed("systemctl start cybexos-maintenance-auto.service")
    automatic_status = json.loads(machine.succeed("cybex maintenance status"))
    assert automatic_status["state"] == "skipped" and "confirmed deployment" in automatic_status["error"], automatic_status
    machine.fail("test -e /etc/cybexos/installer")
    machine.fail("cybexos-install --help >/dev/null && cybexos-install </dev/null")
    machine.succeed("test -e /etc/pam.d/cybexos-lock")
    machine.succeed("test -r /run/current-system/sw/share/cybexos/defaults/fish-config.fish")
    machine.succeed("test -r /run/current-system/sw/share/cybexos/skill/SKILL.md")
    machine.succeed("cybex --help | grep 'Cybex OS'")
    machine.succeed("grep '^Theme=cybexos$' /etc/plymouth/plymouthd.conf")
    machine.succeed("test -r /etc/plymouth/themes/cybexos/cybexos.script")
    machine.succeed("test -r /run/current-system/sw/share/icons/hicolor/32x32/apps/cybexos.png")
    machine.succeed("test -r /run/current-system/sw/share/applications/cybexos.desktop")
    machine.succeed("test -r /run/current-system/sw/share/cybexos/fastfetch/cybexos-large.fastfetch.txt")
    machine.succeed("runuser -u tester -- cybexos-personal-init")
    machine.succeed("test -r /home/tester/.config/voxtype/config.toml && test -r /home/tester/.agents/skills/cybexos/SKILL.md")
    machine.succeed("runuser -u tester -- test -w /home/tester/.config/nvim/init.lua")
    machine.succeed("runuser -u tester -- fish -c true")
    machine.succeed("! grep -q '@CYBEXOS_FASTFETCH@' /home/tester/.config/fastfetch/config.jsonc")
    machine.succeed("systemctl is-active display-manager")
    machine.succeed("cybexos-desktop-check --system $(readlink -f /run/current-system)")
    # The parser must reject a real invalid declaration as well as accepting
    # the full vendor configuration without its former timer SIGSEGV.
    machine.succeed("install -d -m0700 /run/cybexos-verifier-test")
    machine.fail("XDG_RUNTIME_DIR=/run/cybexos-verifier-test Hyprland --i-am-really-stupid --verify-config --config ${invalidConfiguration} > /run/cybexos-verifier-test/result 2>&1")
    machine.succeed("grep -F 'unknown config key' /run/cybexos-verifier-test/result")
    machine.succeed("rm -rf /run/cybexos-verifier-test")
    # Exercise the packaged script plugin and its actual password callback,
    # independently of SDDM. This is a splash/password-UI check, not a LUKS
    # installation or physical display qualification.
    machine.succeed("systemctl stop display-manager.service")
    machine.succeed("systemd-run --unit=cybexos-plymouth-test --service-type=exec -- $(command -v plymouthd) --no-daemon --mode=boot --tty=/dev/tty2 --kernel-command-line='quiet splash plymouth.ignore-serial-consoles' --debug --debug-file=/run/cybexos-plymouth.log")
    machine.wait_until_succeeds("plymouth --ping", timeout=30)
    machine.succeed("plymouth --show-splash; chvt 2")
    machine.sleep(2)
    machine.screenshot("cybexos-plymouth-splash")
    machine.succeed("systemd-run --unit=cybexos-plymouth-ask --service-type=exec -- $(command -v plymouth) ask-for-password --prompt='Unlock Cybex OS qualification disk' --command=${passwordSink}")
    machine.sleep(2)
    machine.screenshot("cybexos-plymouth-unlock")
    machine.send_chars("qualification-password")
    machine.sleep(1)
    machine.screenshot("cybexos-plymouth-password")
    machine.send_key("ret")
    try:
        machine.wait_until_succeeds("grep -q qualification-password /run/cybexos-plymouth-answer", timeout=30)
    except Exception:
        machine.log(machine.succeed("journalctl -u cybexos-plymouth-test -u cybexos-plymouth-ask --no-pager; test ! -e /run/cybexos-plymouth.log || cat /run/cybexos-plymouth.log"))
        raise
    machine.succeed("plymouth quit")
    machine.fail("grep -Ei 'script.*(parse error|syntax error)|failed to load.*cybexos' /run/cybexos-plymouth.log")
    machine.succeed("systemctl start display-manager.service")
    # The greeter has already been exercised. Stop its software renderer while
    # Nix evaluates under TCG; staging checks the candidate independently of an
    # authenticated live desktop, which is required later for confirmation.
    machine.succeed("systemctl stop display-manager.service")
    # A real local preview on a booted Cybex OS system: machine-owned source,
    # real locks/archive/build/checker/closure diff, and supervised worker.
    # The full product candidate is prebuilt; activation remains a separate test.
    machine.succeed("mkdir -p /etc/nixos/local; cp ${previewFlake} /etc/nixos/flake.nix; cp ${initialLock} /etc/nixos/flake.lock")
    machine.succeed("cp ${./machine.nix} /etc/nixos/local/configuration.nix; cp ${previewLocal} /etc/nixos/local/default.nix")
    machine.succeed("cp ${../../templates/machine/local/software.nix} /etc/nixos/local/software.nix; cp ${../../templates/machine/local/software.json} /etc/nixos/local/software.json; cp ${../../templates/machine/local/maintenance.nix} /etc/nixos/local/maintenance.nix; cp ${../../templates/machine/local/maintenance.json} /etc/nixos/local/maintenance.json")
    machine.succeed("echo personal-sentinel > /etc/nixos/local/preserved.txt")
    machine.succeed("nix flake lock --offline path:/etc/nixos", timeout=120)
    machine.succeed("cp -r /etc/nixos /var/lib/cybexos/deployed; sha256sum /etc/nixos/flake.nix /etc/nixos/flake.lock /etc/nixos/local/maintenance.json /etc/nixos/local/preserved.txt > /run/cybexos-preview-before.sha256")
    request = machine.succeed("cybex software stage '{\"previous\":[],\"packages\":[\"hello\"]}'")
    request_id = json.loads(request)["requestId"]
    machine.wait_until_succeeds("runuser -u tester -- cybex software request " + request_id + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"state\"] in (\"done\", \"failed\")'", timeout=900)
    status = machine.succeed("cybex update status")
    if json.loads(status)["state"] != "ready":
        machine.log(machine.succeed("cat /var/lib/cybexos/transactions/*/build.log; journalctl -u 'cybexos-software@*' --no-pager -n 30"))
        raise Exception("Local staging failed: " + status)
    machine.succeed("sha256sum -c /run/cybexos-preview-before.sha256")
    software_status = json.loads(status)
    assert software_status["changeKind"] == "software" and software_status["requestId"] == request_id
    assert software_status["software"]["packages"] == ["hello"]
    assert any(row["name"] == "hello" and row["kind"] == "added" for row in software_status["packageChanges"]), software_status["packageChanges"]
    # The readable summary: a command-line program, known components only,
    # and no store paths in what people read. This VM's running system is not
    # built from the preview flake, so its NixOS build differs legitimately.
    highlights = software_status["highlights"]
    assert highlights["schema"] == 1, highlights
    assert {row["id"] for row in highlights["components"]} <= {"cybexos", "nixos", "kernel", "graphics", "nvidia", "firmware", "hyprland"}, highlights
    assert not any(row["before"] == row["after"] for row in highlights["components"]), highlights
    assert any(row["name"] == "hello" and row["kind"] == "added" and row["before"] is None for row in highlights["tools"]), highlights
    assert "/nix/store" not in json.dumps(highlights), highlights
    transaction = software_status["transaction"]
    machine.succeed("test -x $(readlink -f /var/lib/cybexos/transactions/" + transaction + "/roots/system)/sw/bin/hello")
    machine.succeed("cmp /etc/nixos/flake.lock /var/lib/cybexos/transactions/" + transaction + "/config/flake.lock")
    machine.succeed("cybex software list | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"desired\"] == []'")
    machine.wait_until_succeeds("cybex software request " + request_id + " | grep done")
    policy_request = json.loads(machine.succeed("cybex maintenance policy '{\"previous\":{\"automatic\":true,\"keepConfirmed\":5,\"keepDays\":30},\"policy\":{\"automatic\":false,\"keepConfirmed\":10,\"keepDays\":60}}'"))["requestId"]
    machine.wait_until_succeeds("runuser -u tester -- cybex maintenance request " + policy_request + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"state\"] in (\"done\",\"failed\")'", timeout=900)
    policy_status = json.loads(machine.succeed("cybex update status"))
    assert policy_status["state"] == "ready" and policy_status["changeKind"] == "maintenance", policy_status
    candidate = "/var/lib/cybexos/transactions/" + policy_status["transaction"] + "/roots/system"
    assert json.loads(machine.succeed("cat " + candidate + "/etc/cybexos/maintenance.json")) == {"automatic": False, "keepConfirmed": 10, "keepDays": 60}
    assert json.loads(machine.succeed("cat /etc/cybexos/maintenance.json"))["automatic"] is True
    machine.succeed("cmp /etc/nixos/flake.lock /var/lib/cybexos/transactions/" + policy_status["transaction"] + "/config/flake.lock")
    machine.succeed("sha256sum -c /run/cybexos-preview-before.sha256")
    machine.succeed("cybex update status | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s[\"scope\"] == \"local\" and s[\"reviewToken\"] and s[\"inputs\"][\"cybexos\"]'")
    # Exercise the same authenticated request -> UUID systemd worker -> durable
    # status boundary used by the desktop, including preflight rejection.
    machine.succeed("echo later-personal-edit >> /etc/nixos/local/preserved.txt")
    rejected = json.loads(machine.succeed("cybex update apply " + policy_status["transaction"] + " " + policy_status["reviewToken"]))
    machine.wait_until_succeeds("cybex update request " + rejected["requestId"] + " | grep '\"state\": \"failed\"'")
    stale = json.loads(machine.succeed("runuser -u tester -- cybex update status"))
    assert stale["state"] == "stale" and not stale["reviewToken"], stale
    assert "configuration changed" in stale["request"]["error"], stale
    machine.succeed("test ! -e /var/lib/cybexos/pending.json; grep later-personal-edit /etc/nixos/local/preserved.txt")
    discarded = json.loads(machine.succeed("cybex update discard " + policy_status["transaction"]))
    machine.wait_until_succeeds("cybex update request " + discarded["requestId"] + " | grep '\"state\": \"done\"'")
    cleared = json.loads(machine.succeed("runuser -u tester -- cybex update status"))
    assert cleared["state"] == "idle" and cleared["transaction"] is None and not cleared["packageChanges"], cleared
    update = json.loads(machine.succeed("cybex update stage local"))
    assert update["unit"] == "cybexos-update@" + update["requestId"] + ".service", update
    machine.wait_until_succeeds("cybex update request " + update["requestId"] + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"state\"] in (\"done\",\"failed\")'", timeout=900)
    prepared = json.loads(machine.succeed("runuser -u tester -- cybex update status"))
    assert prepared["state"] == "ready" and prepared["request"]["state"] == "done", prepared
    assert prepared["progress"] is None and prepared["finishedAt"] >= prepared["operationStartedAt"], prepared
    machine.sleep(2)
    assert json.loads(machine.succeed("cybex update status"))["elapsedSeconds"] == prepared["elapsedSeconds"], prepared
    # A prepared change belongs to the person: background preparation waits.
    machine.succeed("systemctl start cybexos-update-auto.service")
    machine.succeed("journalctl -u cybexos-update-auto.service --no-pager | grep -F '\"skipped\": \"ready\"'")
    assert json.loads(machine.succeed("cat /var/lib/cybexos/update-request.json"))["id"] == update["requestId"]
    assert prepared["request"]["id"] == update["requestId"] and prepared["reviewToken"], prepared
    machine.succeed("grep later-personal-edit /etc/nixos/local/preserved.txt")
    assert not prepared["error"], prepared
    # Kill a real worker in preparation and detect interruption in this boot.
    machine.succeed("cp ${interruptedBuild} /etc/nixos/local/interrupted.nix; sed -i 's@./configuration.nix@./configuration.nix ./interrupted.nix@' /etc/nixos/local/default.nix")
    interrupted = json.loads(machine.succeed("cybex update stage local"))
    try:
        machine.wait_until_succeeds("cybex update status | python3 -c 'import json,sys; s=json.load(sys.stdin); p=s.get(\"progress\") or {}; assert s[\"state\"] == \"building\" and p.get(\"schema\") == 1 and p.get(\"builds\", {}).get(\"active\", 0) > 0'", timeout=180)
    except Exception:
        machine.log(machine.succeed("cybex update status; tail -n 50 /var/lib/cybexos/transactions/*/build.log"))
        raise
    machine.succeed("systemctl kill --kill-whom=all --signal=KILL " + interrupted["unit"])
    machine.wait_until_succeeds("runuser -u tester -- cybex update status | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s[\"state\"] == \"interrupted\" and s[\"request\"][\"state\"] == \"failed\" and s[\"progress\"] is None'", timeout=60)
    machine.succeed("test ! -e /var/lib/cybexos/pending.json; grep later-personal-edit /etc/nixos/local/preserved.txt")
    machine.succeed("cp ${previewLocal} /etc/nixos/local/default.nix; rm /etc/nixos/local/interrupted.nix")
    machine.succeed("systemctl start display-manager.service")
    # The normal NixOS daemon, host keys and PAM must support a real password
    # login. Settings changes only a persistent switch, without an OS rebuild.
    ssh = "${pkgs.sshpass}/bin/sshpass -p qualification-only ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password tester@127.0.0.1 true"
    assert not json.loads(machine.succeed("cybexos-ssh-server status"))["enabled"]
    machine.fail("systemctl is-active --quiet sshd.service")
    machine.succeed("cybexos-ssh-server enable")
    machine.wait_for_unit("sshd.service")
    machine.succeed(ssh)
    # A Ctrl-Alt-Delete reboot is intercepted by the graphical greeter.
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_unit("sshd.service")
    machine.succeed(ssh)
    machine.succeed("cybexos-ssh-server disable")
    machine.succeed("systemctl start sshd.service")
    machine.fail("systemctl is-active --quiet sshd.service")
    assert not json.loads(machine.succeed("cybexos-ssh-server status"))["enabled"]
  '';
}
