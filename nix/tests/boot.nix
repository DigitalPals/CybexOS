# Boots the installed boot loader in OVMF. The disk is installed through
# installBootLoader inside nixos-enter, as nixos-install does, onto an ESP of
# the installer's size. Generations are real system profiles and the updater's
# own boot selection runs between real reboots. The screen shows the product's
# boot: the instrumentation's console level and serial console, which would
# switch Plymouth to its text view, are kept off it. This is VM qualification
# of the boot menu, quiet boot and trial selection, not of physical firmware.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "cybexos-boot";
  nodes.machine = { config, lib, pkgs, modulesPath, ... }:
    let
      diskImage = import "${modulesPath}/../lib/make-disk-image.nix" {
        inherit config lib pkgs;
        format = "qcow2";
        partitionTableType = "efi";
        bootSize = "${toString config.cybexos.installation.espGiB}G";
        touchEFIVars = true;
        installBootLoader = true;
        copyChannel = false;
      };
    in {
      imports = [ module ];
      cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
      networking.hostName = "machine";
      users.users.tester.initialPassword = "qualification-only";
      boot.consoleLogLevel = lib.mkForce 3;
      boot.kernelParams = [ "plymouth.ignore-serial-consoles" ];
      environment.etc."cybexos-boot-test".text = lib.mkDefault "previous";
      # The candidate is a separate system; this generation's own menu entries
      # therefore form a nested submenu, as a personal specialisation would.
      specialisation.candidate.configuration.environment.etc."cybexos-boot-test".text = "candidate";
      # The previous boot loader, only to compare loading the same initrd.
      specialisation.systemd-boot.configuration = {
        boot.loader.grub.enable = lib.mkForce false;
        boot.loader.systemd-boot.enable = true;
      };
      system.build.diskImage = diskImage;
      virtualisation = {
        directBoot.enable = false;
        useEFIBoot = true;
        efi.variables = "${diskImage}/efi-vars.fd";
        useDefaultFilesystems = false;
        bootPartition = null;
        fileSystems = {
          "/" = { device = "/dev/vda2"; fsType = "ext4"; };
          "/boot" = { device = "/dev/vda1"; fsType = "vfat"; noCheck = true; };
        };
        # As the installation harness: systemd-boot's EFI stub cannot place
        # this 1.46 GB initrd in a 4 GiB guest; GRUB can.
        memorySize = 12288;
        cores = 4;
        graphics = true;
        # Ignore host QEMU configuration, as the installation harness does.
        qemu.options = [ "-no-user-config" ];
      };
      system.stateVersion = "26.05";
    };
  testScript = { nodes, ... }:
    let
      node = nodes.machine;
      trial = "${node.cybexos.updaterPackage}/bin/cybexos-boot-trial";
      grub = pkgs.grub2_efi;
    in ''
      import json
      import os
      import subprocess
      import tempfile
      import time

      disk = tempfile.NamedTemporaryFile(suffix=".qcow2")
      subprocess.run(["${node.virtualisation.qemu.package}/bin/qemu-img", "create", "-f", "qcow2",
                      "-b", "${node.system.build.diskImage}/nixos.qcow2", "-F", "qcow2", disk.name], check=True)
      os.environ["NIX_DISK_IMAGE"] = disk.name
      previous = "${node.system.build.toplevel}"
      # Normal boots with the same five-second menu; first and one-shot boots differ.
      timings = {"grub": [], "systemd-boot": []}

      def boot(loader=None, screenshots=0):
          started = time.monotonic()
          machine.start()
          for index in range(screenshots):
              time.sleep(1)
              machine.screenshot(f"boot-menu-{index:02d}")
          machine.wait_for_unit("multi-user.target")
          if loader:
              timings[loader].append(round(time.monotonic() - started, 1))

      def reboot(loader=None, screenshots=0):
          machine.shutdown()
          boot(loader, screenshots)

      def booted():
          return machine.succeed("readlink -f /run/booted-system").strip()

      def environment():
          listed = machine.succeed("${grub}/bin/grub-editenv /boot/grub/grubenv list")
          return dict(line.split("=", 1) for line in listed.splitlines())

      def selection(system):
          return "cybexos-generations>cybexos-system-" + system[len("/nix/store/"):][:32]

      boot()
      assert booted() == previous
      candidate = machine.succeed(f"readlink -f {previous}/specialisation/candidate").strip()

      with subtest("menu has the installer theme and identifies exact systems"):
          machine.succeed("cmp /boot/theme/theme.txt ${node.cybexos.bootTheme}/theme.txt")
          machine.succeed("cmp /boot/theme/logo.png ${node.cybexos.bootTheme}/logo.png")
          machine.succeed("grep -q '^ *set theme=.*/theme/theme.txt$' /boot/grub/grub.cfg")
          machine.succeed("grep -q 'submenu \"Cybex OS - All configurations\" --class submenu --id cybexos-generations {' /boot/grub/grub.cfg")
          machine.fail("grep -E '^ *(menuentry|submenu) \"NixOS' /boot/grub/grub.cfg")
          machine.succeed("tail -n 3 /boot/grub/grub.cfg | grep -q '^  halt$'")
          machine.succeed("${grub}/bin/grub-script-check /boot/grub/grub.cfg")
          machine.succeed("cmp /boot/EFI/CybexOS/grubx64.efi /boot/EFI/BOOT/BOOTX64.EFI")
          # The firmware booted its own entry, named for Cybex OS, not NixOS.
          machine.succeed("efibootmgr | grep -q \"^Boot$(efibootmgr | sed -n 's/^BootCurrent: //p')\\* CybexOS\"")
          machine.fail("efibootmgr | grep -qi nixos")
          machine.succeed("test \"$(jq -r .loader /etc/cybexos/boot.json)\" = grub")

      with subtest("boot is quiet"):
          cmdline = machine.succeed("cat /proc/cmdline").split()
          assert "quiet" in cmdline and "udev.log_level=3" in cmdline, cmdline
          assert [p for p in cmdline if p.startswith("loglevel=")] == ["loglevel=3"], cmdline
          assert cmdline.index("quiet") < cmdline.index("loglevel=3"), cmdline
          assert machine.succeed("cut -f1 /proc/sys/kernel/printk").strip() == "3"
          machine.succeed("grep -q \"background_color '${node.cybexos.bootTheme.background}'\" /boot/grub/grub.cfg")

      # A newer generation with the floating top-level entry, like profile().
      machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {candidate}")
      machine.succeed(f"{candidate}/bin/switch-to-configuration boot")
      machine.succeed(f"grep -qF 'if [ \"''${{default}}\" = \"{selection(candidate)}\" ]; then' /boot/grub/grub.cfg")

      with subtest("a persistent selection outranks the newest generation"):
          machine.succeed(f"${trial} --restore {previous}")
          assert environment()["saved_entry"].startswith("cybexos-generations>cybexos-group-"), environment()
          reboot("grub")
          assert booted() == previous

      with subtest("a trial boots once, then the previous default returns"):
          machine.succeed(f"${trial} {candidate} {previous}")
          armed = environment()
          assert armed["next_entry"] == selection(candidate), armed
          reboot()
          assert booted() == candidate
          machine.succeed("test \"$(cat /etc/cybexos-boot-test)\" = candidate")
          consumed = environment()
          assert consumed["next_entry"] == "" and consumed["saved_entry"] == armed["saved_entry"], (armed, consumed)
          reboot("grub")
          assert booted() == previous

      with subtest("commit makes the trial the default"):
          machine.succeed(f"${trial} --commit {candidate}")
          # The menu, kernel loading, splash and login screen.
          reboot(screenshots=30)
          assert booted() == candidate
          machine.succeed(f"${trial} {previous} {candidate}")
          machine.succeed("${trial} --disarm")
          assert environment() == {"saved_entry": selection(candidate)}, environment()

      with subtest("loading time against systemd-boot"):
          systemd_boot = machine.succeed(f"readlink -f {previous}/specialisation/systemd-boot").strip()
          machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {systemd_boot}")
          machine.succeed(f"NIXOS_INSTALL_BOOTLOADER=1 {systemd_boot}/bin/switch-to-configuration boot")
          reboot("systemd-boot")
          assert booted() == systemd_boot
          machine.succeed("test -e /sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f")
          reboot("systemd-boot")
          machine.log("Seconds from start to multi-user.target: " + json.dumps(timings))
      machine.shutdown()
      (machine.out_dir / "boot-timings.json").write_text(json.dumps(timings) + "\n")
    '';
}
