{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.sentinel;

  script = pkgs.writeShellScript "sentinel" (builtins.readFile ../scripts/sentinel.sh);
  versioned = pkgs.writeText "sentinel-versioned" (lib.concatLines cfg.versioned);
  mail = pkgs.writeShellScript "sentinel-mail" (config.alerts.mailCommand
    "printf 'Subject: [%s] sentinel: something new\\n\\n' '${config.networking.hostName}'");
in
{
  imports = [ ./alerts.nix ];

  options.sentinel = {
    enable = mkEnableOption ''
      a daily pass that mails, through alerts, what this machine has not shown
      before: ssh logins from a new key or a new network, a key accepted from
      outside /etc/ssh/authorized_keys.d, processes, units and executables in
      temporary directories that do not come from the store, and store paths
      whose content fails its hash. The first pass mails all it sees'';
    at = mkOption {
      type = types.str;
      default = "*-*-* 08:00:00 America/Mexico_City";
      description = "When the pass runs, as a systemd OnCalendar value; a pass missed while the machine was off runs at boot.";
    };
    versioned = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/home/*/.vscode-server/code-*" ];
      description = ''
        Globs of paths outside the store that update themselves. A new path
        matching one is learned without a mail; one already known still mails
        when its content changes.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = config.alerts.recipientsFile != null;
      message = "sentinel mails through alerts, so alerts.recipientsFile has to be set.";
    }];

    services.openssh.settings.LogLevel = lib.mkDefault "VERBOSE";

    systemd.services.sentinel = {
      description = "What this machine has not shown before";
      path = with pkgs; [ coreutils findutils gawk gnused gnugrep nix systemd ];
      environment.SENTINEL_MAIL = "${mail}";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "sentinel";
        StateDirectoryMode = "0700";
        ExecStart = "${script} /var/lib/sentinel ${versioned}";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.sentinel = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.at;
        Persistent = true;
      };
    };
  };
}
