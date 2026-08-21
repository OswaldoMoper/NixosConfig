{ lib, ... }:
with lib; {
  options.deployment = mkOption {
    description = "Configuración cruda para deploy-rs";
    default = {};
    type = types.attrsOf (types.submodule {
      options = {
        hostname = mkOption { type = types.str; };
        fastConnection = mkOption { type = types.bool; default = false; };
        profiles = mkOption {
          default = {};
          type = types.attrsOf (types.submodule {
            options = {
              sshUser = mkOption { type = types.str; default = "admin"; };
              user = mkOption { type = types.str; default = "root"; };
              path = mkOption { type = types.package; };
              magicRollback = mkOption {
                type = types.nullOr types.bool;
                default = null;
                description = ''
                  Null leaves deploy-rs's own default (true), which reverts the
                  activation if the host stops answering afterwards.

                  Setting it false trades that net for not being rolled back by
                  a false alarm: a benign non-zero from user activation reads as
                  a failed deploy, and the rollback re-activation can hang with
                  every service stopped.
                '';
              };
              autoRollback = mkOption {
                type = types.nullOr types.bool;
                default = null;
                description = "Null leaves deploy-rs's default (true): revert when activation itself fails.";
              };
            };
          });
        };
      };
    });
  };
}