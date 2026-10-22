{ lib, ... }:
let preferences = builtins.fromJSON (builtins.readFile ./desktop-settings.json);
in { config = lib.mkMerge [
  (lib.mkIf (preferences ? timezone) { time.timeZone = lib.mkOverride 900 preferences.timezone; })
  (lib.mkIf (preferences ? locale) { i18n.defaultLocale = lib.mkOverride 900 preferences.locale; })
]; }
