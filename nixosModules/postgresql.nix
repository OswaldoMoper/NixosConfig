{ config, pkgs, lib, ... }:
# This module configures PostgreSQL on NixOS
let
  parseInt = s: if s == "" then 0 else builtins.fromJSON s;
  availableVersions =
    builtins.filter (v: builtins.match "^[0-9]+$" v != null)
      (builtins.concatMap (name: [
         (builtins.substring 11 (builtins.stringLength name - 11) name)
      ]) (builtins.filter (name: builtins.match "^postgresql_[0-9]+$" name != null)
         (builtins.attrNames pkgs)));
  sortedVersions = builtins.sort (a: b: parseInt a > parseInt b) availableVersions;
  targetVersion = toString (builtins.head sortedVersions);
in
{
  services.postgresql = {
    enable = true;
    package = pkgs."postgresql_${targetVersion}";
    enableTCPIP = true;
    authentication = pkgs.lib.mkOverride 10 ''
      local all all trust
      host all all ::1/128 trust
      host all all 127.0.0.1/32 trust
    '';
    initialScript = pkgs.writeText "backend-initScript" ''
      CREATE ROLE analyzer WITH LOGIN PASSWORD 'anapass';
      CREATE DATABASE aanalyzer_yesod;
      ALTER DATABASE aanalyzer_yesod OWNER TO analyzer;
      GRANT ALL PRIVILEGES ON DATABASE aanalyzer_yesod TO analyzer;
      ALTER SCHEMA public OWNER TO analyzer;
    '';
    settings.log_statement = "all";
  };
}