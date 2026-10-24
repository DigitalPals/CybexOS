{ pkgs, module, inputSources, candidate }:
let
  passwordSink = pkgs.writeShellScript "nerdos-plymouth-answer" ''
    ${pkgs.coreutils}/bin/cat > /run/nerdos-plymouth-answer
  '';
  sourceLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  upstream = sourceLock.nodes.${sourceLock.nodes.${sourceLock.root}.inputs.nixpkgs};
  initialLock = pkgs.writeText "nerdos-preview-lock.json" (builtins.toJSON {
    version = 7; root = "root";
    nodes = { root.inputs.nixpkgs = "nixpkgs"; nixpkgs = upstream; };
  });
  previewFlake = pkgs.writeText "nerdos-preview-flake.nix" ''
    {
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
      inputs.nerdos.url = "path:${../..}";
      inputs.nerdos.inputs.nixpkgs.follows = "nixpkgs";
      outputs = { nixpkgs, nerdos, ... }: {
        nixosConfigurations.nerdos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ nerdos.nixosModules.default ./local ];
        };
      };
    }
  '';
  previewLocal = pkgs.writeText "nerdos-preview-local.nix" ''
    { imports = [ ./configuration.nix ./software.nix ./maintenance.nix ]; }
  '';
  invalidConfiguration = pkgs.writeText "nerdos-verifier-invalid.lua" ''
  dofile("/etc/nerdos/runtime/hypr/hyprland.lua")
  hl.config({ general = { qualification_invalid_option = 1 } })
'';
in pkgs.testers.runNixOSTest {
  name = "nerdos-lifecycle";
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    nerdos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
    virtualisation = { memorySize = 4096; cores = 4; graphics = true; diskSize = 4096; };
    networking.hostName = "machine";
    users.users.tester.initialPassword = "qualification-only";
    # Retain the complete candidate and its exact input sources. Staging must
    # use the real Nix/updater path without requiring external delivery in a VM.
    system.extraDependencies = inputSources ++ [ candidate previewFlake initialLock pkgs.hello ];
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
    machine.wait_for_unit("nerdos-network-defaults.service")
    machine.wait_for_unit("systemd-resolved.service")
    assert machine.succeed("readlink -f /etc/resolv.conf").strip().endswith("stub-resolv.conf")
    assert machine.succeed("nmcli --escape no -g ipv4.dns connection show 'NerdOS Wired'").strip() == "8.8.8.8,8.8.4.4"
    assert machine.succeed("nmcli --escape no -g ipv6.dns connection show 'NerdOS Wired'").strip() == "2001:4860:4860::8888,2001:4860:4860::8844"
    assert json.loads(machine.succeed("tailscale status --json"))["BackendState"] == "NeedsLogin"
    helper = "/etc/nerdos/runtime/quickshell/scripts/network-tool.py"
    machine.succeed("printf '%s\\n' '{\"provider\":\"Automatic\"}' | python3 " + helper + " dns")
    profile_before = machine.succeed("sha256sum /etc/NetworkManager/system-connections/nerdos-wired.nmconnection")
    machine.succeed("systemctl restart nerdos-network-defaults.service NetworkManager.service")
    assert machine.succeed("sha256sum /etc/NetworkManager/system-connections/nerdos-wired.nmconnection") == profile_before
    assert machine.succeed("nmcli -g ipv4.ignore-auto-dns connection show 'NerdOS Wired'").strip() == "no"
    assert not machine.succeed("nmcli -g ipv4.dns connection show 'NerdOS Wired'").strip()
    # Even without its marker the initializer preserves existing profiles.
    machine.succeed("rm /var/lib/nerdos-network/defaults-initialized; systemctl restart nerdos-network-defaults.service")
    assert machine.succeed("sha256sum /etc/NetworkManager/system-connections/nerdos-wired.nmconnection") == profile_before
    machine.succeed("printf '%s\\n' '{\"provider\":\"Google\"}' | python3 " + helper + " dns")
    # Recovery is intentionally ordered after these services. Waiting only
    # for multi-user.target can observe it before the first worker invocation.
    machine.wait_until_succeeds("test -n \"$(systemctl show nerdos-recover.service -p ExecMainExitTimestamp --value)\"")
    machine.succeed("test \"$(systemctl show nerdos-recover.service -p Result --value)\" = success")
    machine.succeed("test \"$(systemctl show nerdos-recover.service -p ExecMainStatus --value)\" = 0")
    machine.succeed("systemctl is-active nerdos-recover.service")
    recovery_invocation = machine.succeed("systemctl show nerdos-recover.service -p InvocationID --value").strip()
    # switch-to-configuration starts active targets again while the applying
    # worker owns this lock. Boot recovery must stay completed for this boot,
    # rather than being reentered and poisoning the activation transaction.
    machine.succeed("flock /var/lib/nerdos/operation.lock systemctl start multi-user.target")
    assert machine.succeed("systemctl show nerdos-recover.service -p InvocationID --value").strip() == recovery_invocation
    machine.succeed("systemctl is-active nerdos-recover.service")
    machine.fail("journalctl -b --no-pager | grep -Ei 'nerdos-recover.*(ordering cycle|deleted.*job)|ordering cycle.*nerdos-recover'")
    machine.succeed("nerd update status | grep idle")
    assert json.loads(machine.succeed("cat /etc/nerdos/maintenance.json")) == {"automatic": True, "keepConfirmed": 5, "keepDays": 30}
    machine.succeed("systemctl is-active nerdos-maintenance-auto.timer")
    machine.succeed("systemctl start nerdos-maintenance-auto.service")
    automatic_status = json.loads(machine.succeed("nerd maintenance status"))
    assert automatic_status["state"] == "skipped" and "confirmed deployment" in automatic_status["error"], automatic_status
    machine.fail("test -e /etc/nerdos/installer")
    machine.fail("nerdos-install --help >/dev/null && nerdos-install </dev/null")
    machine.succeed("test -e /etc/pam.d/nerdos-lock")
    machine.succeed("test -r /run/current-system/sw/share/nerdos/defaults/fish-config.fish")
    machine.succeed("test -r /run/current-system/sw/share/nerdos/skill/SKILL.md")
    machine.succeed("nerd --help | grep 'Opinionated System'")
    machine.succeed("grep '^Theme=nerdos$' /etc/plymouth/plymouthd.conf")
    machine.succeed("test -r /etc/plymouth/themes/nerdos/nerdos.script")
    machine.succeed("test -r /run/current-system/sw/share/icons/hicolor/32x32/apps/nerdos.png")
    machine.succeed("test -r /run/current-system/sw/share/applications/nerdos.desktop")
    machine.succeed("test -r /run/current-system/sw/share/nerdos/fastfetch/nerdos-large.fastfetch.txt")
    machine.succeed("runuser -u tester -- nerdos-personal-init")
    machine.succeed("test -r /home/tester/.config/voxtype/config.toml && test -r /home/tester/.agents/skills/nerdos/SKILL.md")
    machine.succeed("runuser -u tester -- test -w /home/tester/.config/nvim/init.lua")
    machine.succeed("runuser -u tester -- fish -c true")
    machine.succeed("! grep -q '@NERDOS_FASTFETCH@' /home/tester/.config/fastfetch/config.jsonc")
    machine.succeed("systemctl is-active display-manager")
    machine.succeed("nerdos-desktop-check --system $(readlink -f /run/current-system)")
    # The parser must reject a real invalid declaration as well as accepting
    # the full vendor configuration without its former timer SIGSEGV.
    machine.succeed("install -d -m0700 /run/nerdos-verifier-test")
    machine.fail("XDG_RUNTIME_DIR=/run/nerdos-verifier-test Hyprland --i-am-really-stupid --verify-config --config ${invalidConfiguration} > /run/nerdos-verifier-test/result 2>&1")
    machine.succeed("grep -F 'unknown config key' /run/nerdos-verifier-test/result")
    machine.succeed("rm -rf /run/nerdos-verifier-test")
    # Exercise the packaged script plugin and its actual password callback,
    # independently of SDDM. This is a splash/password-UI check, not a LUKS
    # installation or physical display qualification.
    machine.succeed("systemctl stop display-manager.service")
    machine.succeed("systemd-run --unit=nerdos-plymouth-test --service-type=exec -- $(command -v plymouthd) --no-daemon --mode=boot --tty=/dev/tty2 --kernel-command-line='quiet splash plymouth.ignore-serial-consoles' --debug --debug-file=/run/nerdos-plymouth.log")
    machine.wait_until_succeeds("plymouth --ping", timeout=30)
    machine.succeed("plymouth --show-splash; chvt 2")
    machine.sleep(2)
    machine.screenshot("nerdos-plymouth-splash")
    machine.succeed("systemd-run --unit=nerdos-plymouth-ask --service-type=exec -- $(command -v plymouth) ask-for-password --prompt='Unlock NerdOS qualification disk' --command=${passwordSink}")
    machine.sleep(2)
    machine.screenshot("nerdos-plymouth-unlock")
    machine.send_chars("qualification-password")
    machine.sleep(1)
    machine.screenshot("nerdos-plymouth-password")
    machine.send_key("ret")
    try:
        machine.wait_until_succeeds("grep -q qualification-password /run/nerdos-plymouth-answer", timeout=30)
    except Exception:
        machine.log(machine.succeed("journalctl -u nerdos-plymouth-test -u nerdos-plymouth-ask --no-pager; test ! -e /run/nerdos-plymouth.log || cat /run/nerdos-plymouth.log"))
        raise
    machine.succeed("plymouth quit")
    machine.fail("grep -Ei 'script.*(parse error|syntax error)|failed to load.*nerdos' /run/nerdos-plymouth.log")
    machine.succeed("systemctl start display-manager.service")
    # The greeter has already been exercised. Stop its software renderer while
    # Nix evaluates under TCG; staging checks the candidate independently of an
    # authenticated live desktop, which is required later for confirmation.
    machine.succeed("systemctl stop display-manager.service")
    # A real local preview on a booted NerdOS system: machine-owned source,
    # real locks/archive/build/checker/closure diff, and supervised worker.
    # The full product candidate is prebuilt; activation remains a separate test.
    machine.succeed("mkdir -p /etc/nixos/local; cp ${previewFlake} /etc/nixos/flake.nix; cp ${initialLock} /etc/nixos/flake.lock")
    machine.succeed("cp ${./machine.nix} /etc/nixos/local/configuration.nix; cp ${previewLocal} /etc/nixos/local/default.nix")
    machine.succeed("cp ${../../templates/machine/local/software.nix} /etc/nixos/local/software.nix; cp ${../../templates/machine/local/software.json} /etc/nixos/local/software.json; cp ${../../templates/machine/local/maintenance.nix} /etc/nixos/local/maintenance.nix; cp ${../../templates/machine/local/maintenance.json} /etc/nixos/local/maintenance.json")
    machine.succeed("echo personal-sentinel > /etc/nixos/local/preserved.txt")
    machine.succeed("nix flake lock --offline path:/etc/nixos", timeout=120)
    machine.succeed("cp -r /etc/nixos /var/lib/nerdos/deployed; sha256sum /etc/nixos/flake.nix /etc/nixos/flake.lock /etc/nixos/local/maintenance.json /etc/nixos/local/preserved.txt > /run/nerdos-preview-before.sha256")
    request = machine.succeed("nerd software stage '{\"previous\":[],\"packages\":[\"hello\"]}'")
    request_id = json.loads(request)["requestId"]
    machine.wait_until_succeeds("runuser -u tester -- nerd software request " + request_id + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"state\"] in (\"done\", \"failed\")'", timeout=900)
    status = machine.succeed("nerd update status")
    if json.loads(status)["state"] != "ready":
        machine.log(machine.succeed("cat /var/lib/nerdos/transactions/*/build.log; journalctl -u 'nerdos-software@*' --no-pager -n 30"))
        raise Exception("Local staging failed: " + status)
    machine.succeed("sha256sum -c /run/nerdos-preview-before.sha256")
    software_status = json.loads(status)
    assert software_status["changeKind"] == "software" and software_status["requestId"] == request_id
    assert software_status["software"]["packages"] == ["hello"]
    transaction = software_status["transaction"]
    machine.succeed("test -x $(readlink -f /var/lib/nerdos/transactions/" + transaction + "/roots/system)/sw/bin/hello")
    machine.succeed("cmp /etc/nixos/flake.lock /var/lib/nerdos/transactions/" + transaction + "/config/flake.lock")
    machine.succeed("nerd software list | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"desired\"] == []'")
    machine.wait_until_succeeds("nerd software request " + request_id + " | grep done")
    policy_request = json.loads(machine.succeed("nerd maintenance policy '{\"previous\":{\"automatic\":true,\"keepConfirmed\":5,\"keepDays\":30},\"policy\":{\"automatic\":false,\"keepConfirmed\":10,\"keepDays\":60}}'"))["requestId"]
    machine.wait_until_succeeds("runuser -u tester -- nerd maintenance request " + policy_request + " | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"state\"] in (\"done\",\"failed\")'", timeout=900)
    policy_status = json.loads(machine.succeed("nerd update status"))
    assert policy_status["state"] == "ready" and policy_status["changeKind"] == "maintenance", policy_status
    candidate = "/var/lib/nerdos/transactions/" + policy_status["transaction"] + "/roots/system"
    assert json.loads(machine.succeed("cat " + candidate + "/etc/nerdos/maintenance.json")) == {"automatic": False, "keepConfirmed": 10, "keepDays": 60}
    assert json.loads(machine.succeed("cat /etc/nerdos/maintenance.json"))["automatic"] is True
    machine.succeed("cmp /etc/nixos/flake.lock /var/lib/nerdos/transactions/" + policy_status["transaction"] + "/config/flake.lock")
    machine.succeed("sha256sum -c /run/nerdos-preview-before.sha256")
    machine.succeed("nerd update status | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s[\"scope\"] == \"local\" and s[\"reviewToken\"] and s[\"inputs\"][\"nerdos\"]'")
    machine.succeed("systemctl start display-manager.service")
  '';
}
