{ config, options, lib, ... }:

let
  inherit (lib) mkIf mkMerge;
  cfg = config.webStack;
in
  {
    config = mkMerge [ (mkIf cfg.enable {
      # `options ? age` guards the attribute so a host without agenix still
      # evaluates, which is how the app modules guard theirs.
      age = lib.mkIf (options ? age) {
        secrets = lib.mkMerge (map
          (a: lib.mapAttrs (_: s: removeAttrs s [ "vmValue" ]) a.secrets)
          (cfg.tunnel.apps ++ cfg.nginx.apps));
      };

      vm.secretValues = lib.mkMerge (map
        (a: lib.mapAttrs (_: s: s.vmValue) (lib.filterAttrs (_: s: s ? vmValue) a.secrets))
        (cfg.tunnel.apps ++ cfg.nginx.apps));

      postgresql.ensure = map (a: {
        database = a.database.name;
        role = a.database.user;
        inherit (a.database) passwordFile;
      }) (lib.filter (a: a.database != null && a.database.provision)
            (cfg.tunnel.apps ++ cfg.nginx.apps));
    })

    # Every name this stack serves, for the watcher to watch; written only
    # where the watcher module is imported, as age is only where agenix is.
    (lib.optionalAttrs (options ? watcher) {
      watcher.sites = mkIf cfg.enable (lib.genAttrs
        (lib.concatMap (a: [ a.domain ] ++ a.aliases ++ a.redirects) cfg.nginx.apps
          ++ lib.attrNames cfg.nginx.redirects)
        (_: { }));
    })
    ];
  }
