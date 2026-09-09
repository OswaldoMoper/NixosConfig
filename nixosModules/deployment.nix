{ lib, ... }:
with lib; {
  options.deployment = mkOption {
    description = "Configuración cruda para deploy-rs";
    default = {};
    type = types.attrsOf (types.submodule {
      options = {
        hostname = mkOption { type = types.str; };
        fastConnection = mkOption { type = types.bool; default = false; };
        checks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "pre-deploy-xesOasis" "hosts-declared" ];
          description = ''
            Which flake checks the deploy gate builds before it deploys this
            node, named as attributes of `checks.<system>`.

            The empty default means every check in the flake, which is right
            when they all speak for every host. It stops being right the moment
            a flake grows checks that belong to one environment: deploying a
            host that runs none of those applications would build them anyway,
            and a gate that does the wrong work gets skipped by hand.

            The node says what concerns it because the node is what knows.
          '';
        };
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