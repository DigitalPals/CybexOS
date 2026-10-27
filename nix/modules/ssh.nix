{ config, lib, pkgs, ... }:
let
  cfg = config.cybexos;
in {
  config = lib.mkIf cfg.enable {
    # Declare the complete NixOS service/PAM/host-key contract in every installed
    # generation. The Settings switch owns only its persistent on/off state.
    services.openssh = {
      enable = lib.mkDefault true;
      openFirewall = lib.mkDefault true;
      startWhenNeeded = lib.mkDefault false;
      settings = {
        PermitRootLogin = lib.mkDefault "no";
        PasswordAuthentication = lib.mkDefault true;
        KbdInteractiveAuthentication = lib.mkDefault false;
        UsePAM = true;
        AllowUsers = lib.mkDefault [ cfg.primaryUser ];
      };
    };
    security.pam.services.sshd = {
      fprintAuth = false;
      u2f.enable = false;
      allowNullPassword = false;
    };
    systemd.services.sshd = lib.mkIf (config.services.openssh.enable && !config.services.openssh.startWhenNeeded) {
      unitConfig.ConditionPathExists = "/var/lib/cybexos/ssh-server/enabled";
    };
    systemd.tmpfiles.rules = [ "d /var/lib/cybexos/ssh-server 0755 root root -" ];
    environment.etc."cybexos/ssh-server.json".text = builtins.toJSON {
      user = cfg.primaryUser;
      ports = config.services.openssh.ports;
      available = config.services.openssh.enable && !config.services.openssh.startWhenNeeded;
    };
    environment.systemPackages = [ (pkgs.writeTextDir "share/polkit-1/actions/org.cybexos.ssh-server.policy" ''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
      <policyconfig>
        <action id="org.cybexos.ssh-server">
          <description>Enable or disable the SSH Server</description>
          <message>Authenticate to change remote login access</message>
          <defaults><allow_any>no</allow_any><allow_inactive>no</allow_inactive><allow_active>auth_admin</allow_active></defaults>
          <annotate key="org.freedesktop.policykit.exec.path">${cfg.updaterPackage}/bin/cybexos-ssh-server</annotate>
        </action>
      </policyconfig>
    '') ];
  };
}
