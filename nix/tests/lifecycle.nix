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
    system.extraDependencies = inputSources ++ [ candidate previewFlake initialLock ];
    system.stateVersion = "26.05";
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
  testScript = ''
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("display-manager.service")
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
    # A real local preview on a booted NerdOS system: machine-owned source,
    # real locks/archive/build/checker/closure diff, and supervised worker.
    # The full product candidate is prebuilt; activation remains a separate test.
    machine.succeed("mkdir -p /etc/nixos/local; cp ${previewFlake} /etc/nixos/flake.nix; cp ${initialLock} /etc/nixos/flake.lock")
    machine.succeed("cp ${./machine.nix} /etc/nixos/local/default.nix")
    machine.succeed("echo personal-sentinel > /etc/nixos/local/preserved.txt")
    machine.succeed("nix flake lock --offline path:/etc/nixos", timeout=120)
    machine.succeed("cp -r /etc/nixos /var/lib/nerdos/deployed; sha256sum /etc/nixos/flake.nix /etc/nixos/flake.lock /etc/nixos/local/preserved.txt > /run/nerdos-preview-before.sha256")
    machine.succeed("nerd update stage local")
    machine.wait_until_succeeds("nerd update status | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"state\"] in (\"ready\", \"failed\")'", timeout=900)
    status = machine.succeed("nerd update status")
    if json.loads(status)["state"] != "ready":
        machine.log(machine.succeed("cat /var/lib/nerdos/transactions/*/build.log"))
        raise Exception("Local staging failed: " + status)
    machine.succeed("sha256sum -c /run/nerdos-preview-before.sha256")
    machine.succeed("nerd update status | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s[\"scope\"] == \"local\" and s[\"reviewToken\"] and s[\"inputs\"][\"nerdos\"]'")
  '';
}
