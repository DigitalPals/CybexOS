{ config, lib, pkgs, ... }:
let cfg = config.cybexos;
    auth = {
      fprintAuth = lib.mkDefault cfg.authentication.fingerprint;
      u2f.enable = lib.mkDefault true;
    };
in {
  options.cybexos.authentication.fingerprint = lib.mkOption { type = lib.types.bool; default = true; };
  config = lib.mkIf cfg.enable {
    security.sudo.wheelNeedsPassword = lib.mkDefault true;
    security.polkit.enable = true;
    services.fprintd.enable = lib.mkDefault cfg.authentication.fingerprint;
    security.pam.u2f = {
      enable = false;
      settings = { # An unmapped key must fall through to password authentication. With a
        # sufficient PAM rule, nouserok=true could authorize an unenrolled user.
        cue = true; nouserok = false; userpresence = 1; origin = "pam://cybexos"; appid = "pam://cybexos"; };
    };
    security.pam.services = {
      sudo = auth;
      polkit-1 = auth;
      # Login always asks for the password to unlock the keyring.
      sddm = { fprintAuth = false; u2f.enable = false; enableGnomeKeyring = true; };
      sddm-autologin = {
        enableGnomeKeyring = true; fprintAuth = false; u2f.enable = false;
        rules.auth.systemd-loadkey = { order = 100; control = "optional"; modulePath = "${pkgs.systemd}/lib/security/pam_systemd_loadkey.so"; };
      };
      # shadow enables null-password login at ordinary priority. The product
      # requires a password even if an account accidentally has an empty hash.
      login = { fprintAuth = false; u2f.enable = false; allowNullPassword = lib.mkForce false; };
      cybexos-lock = { fprintAuth = false; u2f.enable = true; };
    };
    security.apparmor.enable = lib.mkDefault true;
    security.protectKernelImage = lib.mkDefault true;
    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2; "kernel.dmesg_restrict" = 1;
      "kernel.perf_event_paranoid" = 3; "kernel.yama.ptrace_scope" = 1;
      "vm.mmap_min_addr" = 65536;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
    };
    networking.firewall = {
      enable = lib.mkDefault true;
      allowedTCPPorts = [ 53317 ] ++ lib.optionals (cfg.features.localNetworkServices && cfg.features.steam) [ 27015 27036 27037 ];
      allowedUDPPorts = [ 53317 5353 ] ++ lib.optionals (cfg.features.localNetworkServices && cfg.features.steam) [ 27015 10400 10401 ];
      allowedUDPPortRanges = lib.optional (cfg.features.localNetworkServices && cfg.features.steam) { from = 27031; to = 27036; };
    };
    # Private files are runtime paths, never builtins.readFile/imported store content.
    systemd.tmpfiles.rules = [ "d /var/lib/cybexos/secrets 0700 root root -" ];
  };
}
