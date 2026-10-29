# The actual request boundary and systemd worker, with fake device hardware.
# No test may flash host firmware. This qualifies firmware-only orchestration;
# physical devices and vendor capsule execution still need hardware testing.
{ pkgs, module }:
let
  device = {
    id = "qualification-bios"; name = "System Firmware"; vendor = "Qualification";
    from = "1"; to = "2"; needsReboot = true; needsShutdown = false; affectsFde = true;
  };
  helper = pkgs.writeScript "cybexos-firmware-fixture" ''
    #!${pkgs.python3}/bin/python3
    import json, pathlib, sys, time
    device = json.loads(${builtins.toJSON (builtins.toJSON device)})
    installed = pathlib.Path('/var/lib/cybexos/qualification-firmware-installed')
    if sys.argv[1] == 'plan':
        print(json.dumps({'devices': [] if installed.exists() else [device]}))
    elif sys.argv[1] == 'install':
        expected = json.loads(pathlib.Path(sys.argv[sys.argv.index('--plan') + 1]).read_text())
        assert expected == {'devices': [device]}, expected
        def emit(event_name, **fields):
            print(json.dumps({'event': event_name, **fields}), file=sys.stderr, flush=True)
        emit('device', id=device['id'])
        emit('progress', id=device['id'], percent=42, status='device-write')
        emit('request', id=device['id'], kind='immediate', message='Keep external power connected.')
        time.sleep(4)
        installed.touch()
        emit('installed', id=device['id'], needsReboot=True)
        emit('request', id=device['id'], kind='post', message='Restart to finish.')
        emit('summary', installed=1, failed=0, needsReboot=True, needsShutdown=False)
    else:
        sys.exit(2)
  '';
in pkgs.testers.runNixOSTest {
  name = "cybexos-firmware";
  nodes.machine = { config, lib, ... }: {
    imports = [ module ];
    cybexos = {
      enable = true; primaryUser = "tester";
      features = { proprietary = false; steam = false; docker = false; };
    };
    users.users.tester.initialPassword = "qualification-only";
    networking.hostName = "machine";
    boot.loader.systemd-boot.enable = lib.mkForce false;
    # The test instrumentation otherwise forces verbose serial logging.
    boot.consoleLogLevel = lib.mkForce 0;
    boot.kernelParams = [ "plymouth.ignore-serial-consoles" ];
    system.stateVersion = "26.05";
    virtualisation = {
      memorySize = 4096; cores = 4; graphics = true;
      qemu.options = [ "-no-user-config" ];
    };
    # Replace only the helper inside the worker's mount namespace. Everything
    # else is the production CLI, request protocol, worker, engine and reader.
    systemd.services."cybexos-update@".serviceConfig.BindReadOnlyPaths = [
      "${helper}:${config.cybexos.desktopPackage}/bin/cybexos-firmware-update"
    ];
  };
  testScript = ''
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_unit("cybexos-recover.service")
    machine.succeed("cybex update automatic prepare off")
    with subtest("the shared quiet defaults reach the running kernel and both boot stages"):
        cmdline = machine.succeed("cat /proc/cmdline").split()
        assert {"quiet", "loglevel=0", "systemd.show_status=false", "rd.systemd.show_status=false"} <= set(cmdline), cmdline
        assert machine.succeed("cut -f1 /proc/sys/kernel/printk").strip() == "0"

    def status():
        return json.loads(machine.succeed("runuser -u tester -- cybex update status"))

    def request(arguments):
        accepted = json.loads(machine.succeed("cybexos-request " + arguments))
        assert accepted["accepted"] is True, accepted
        return accepted

    with subtest("prepare reviews firmware without activating an OS or flashing"):
        before = machine.succeed("readlink -f /run/current-system").strip()
        accepted = request("stage firmware")
        machine.wait_until_succeeds("cybex update status | grep -q '\"state\": \"ready\"'")
        ready = status()
        assert ready["scope"] == "firmware", ready
        assert ready["firmware"]["devices"][0]["to"] == "2", ready
        machine.fail("test -e /var/lib/cybexos/qualification-firmware-installed")

    with subtest("the supervised worker publishes progress and finishes independently of clients"):
        accepted = request("apply " + ready["transaction"] + " " + ready["reviewToken"])
        machine.wait_until_succeeds("cybex update status | grep -q '\"percent\": 42'")
        installing = status()
        assert installing["state"] == "firmware", installing
        assert installing["firmware"]["requests"][0]["message"] == "Keep external power connected.", installing
        machine.wait_until_succeeds("cybex update request " + accepted["requestId"] + " | grep -q '\"state\": \"done\"'")
        finished = status()
        assert finished["state"] == "done" and finished["firmware"]["needsReboot"], finished
        assert finished["firmware"]["requests"][0]["kind"] == "post", finished
        machine.fail("test -e /var/lib/cybexos/pending.json")
        assert machine.succeed("readlink -f /run/current-system").strip() == before
        machine.succeed("systemctl show " + accepted["unit"] + " -p Result | grep -q Result=success")

    with subtest("a new boot clears the firmware restart requirement"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert status()["firmware"]["needsReboot"] is False
    machine.shutdown()
  '';
}
