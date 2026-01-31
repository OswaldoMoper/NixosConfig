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
            };
          });
        };
      };
    });
  };
}