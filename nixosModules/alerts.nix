{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.alerts;
in
{
  options.alerts = {
    recipientsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/alert-recipients";
      description = ''
        Path on the machine to mail headers naming who is alerted, such as
        `Bcc: a@example.org, b@example.org`, and nothing else: no blank line.
        Read when an alert goes out, so it can be a secret the alerting service
        reads. Sent through the system msmtp account; every recipient sees only
        `undisclosed-recipients`. Null sends no mail.
      '';
    };
    passwordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Path on the machine to the SMTP password, readable by the alerting
        service. Null keeps the msmtp account's own.
      '';
    };
    mailCommand = mkOption {
      type = types.functionTo types.str;
      readOnly = true;
      description = ''
        Given a shell command that prints the mail's Subject header and a blank
        line, the shell command that mails its own standard input after them.
        Meaningful only with recipientsFile set.
      '';
    };
  };

  config = {
    assertions = [{
      assertion = cfg.passwordFile == null || cfg.recipientsFile != null;
      message = "alerts.passwordFile is only read with alerts.recipientsFile.";
    }];

    alerts.mailCommand = headers:
      "{ ${pkgs.gnused}/bin/sed -e '$a\\' ${cfg.recipientsFile}; "
      + "${headers}; ${pkgs.coreutils}/bin/cat; } "
      + "| ${pkgs.msmtp}/bin/msmtp -t --set-to-header=undisclosed_recipients"
      + lib.optionalString (cfg.passwordFile != null)
          " --passwordeval='${pkgs.coreutils}/bin/cat ${cfg.passwordFile}'";
  };
}
