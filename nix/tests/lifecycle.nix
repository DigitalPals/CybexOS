{ pkgs, module }:
let invalidConfiguration = pkgs.writeText "cybexos-verifier-invalid.lua" ''
  dofile("/etc/cybexos/runtime/hypr/hyprland.lua")
  hl.config({ general = { qualification_invalid_option = 1 } })
'';
in pkgs.testers.runNixOSTest {
  name = "cybexos-lifecycle";
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
    virtualisation = { memorySize = 4096; cores = 4; graphics = true; };
    networking.hostName = "machine";
    users.users.tester.initialPassword = "qualification-only";
    system.stateVersion = "26.05";
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("display-manager.service")
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
    machine.fail("test -e /etc/cybexos/installer")
    machine.fail("cybexos-install --help >/dev/null && cybexos-install </dev/null")
    machine.succeed("test -e /etc/pam.d/cybexos-lock")
    machine.succeed("test -r /run/current-system/sw/share/cybexos/defaults/fish-config.fish")
    machine.succeed("test -r /run/current-system/sw/share/cybexos/skill/SKILL.md")
    machine.succeed("runuser -u tester -- cybexos-personal-init")
    machine.succeed("test -r /home/tester/.config/voxtype/config.toml && test -r /home/tester/.agents/skills/cybexos/SKILL.md")
    machine.succeed("runuser -u tester -- test -w /home/tester/.config/nvim/init.lua")
    machine.succeed("runuser -u tester -- fish -c true")
    machine.succeed("systemctl is-active display-manager")
    machine.succeed("cybexos-desktop-check --system $(readlink -f /run/current-system)")
    # The parser must reject a real invalid declaration as well as accepting
    # the full vendor configuration without its former timer SIGSEGV.
    machine.succeed("install -d -m0700 /run/cybexos-verifier-test")
    machine.fail("XDG_RUNTIME_DIR=/run/cybexos-verifier-test Hyprland --i-am-really-stupid --verify-config --config ${invalidConfiguration} > /run/cybexos-verifier-test/result 2>&1")
    machine.succeed("grep -F 'unknown config key' /run/cybexos-verifier-test/result")
    machine.succeed("rm -rf /run/cybexos-verifier-test")
  '';
}
