{ config, options, lib, ... }:

let
  inherit (lib) mkIf mkMerge optionalAttrs;
  cfg = config.webStack;
  apps = cfg.tunnel.apps ++ cfg.nginx.apps;
in
  {
    config = mkMerge [
      (optionalAttrs (options ? age) {
        age.secrets = mkIf cfg.enable (mkMerge (map
          (a: lib.mapAttrs (_: s: removeAttrs s [ "vmValue" ]) a.secrets)
          apps));
      })

      (optionalAttrs (options ? vm) {
        vm.secretValues = mkIf cfg.enable (mkMerge (map
          (a: lib.mapAttrs (_: s: s.vmValue) (lib.filterAttrs (_: s: s ? vmValue) a.secrets))
          apps));
      })

      (optionalAttrs (options ? postgresql) {
        postgresql.ensure = mkIf cfg.enable (map (a: {
          database = a.database.name;
          role = a.database.user;
          inherit (a.database) passwordFile;
        }) (lib.filter (a: a.database != null && a.database.provision) apps));
      })

      (optionalAttrs (options ? watcher) {
        watcher.sites = mkIf cfg.enable (lib.genAttrs
          (lib.concatMap (a: [ a.domain ] ++ a.aliases ++ a.redirects) cfg.nginx.apps
            ++ lib.attrNames cfg.nginx.redirects)
          (_: { }));
      })
    ];
  }
