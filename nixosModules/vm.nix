{ config, lib, ... }:

# Builds every host as a local QEMU VM through NixOS's own vmVariant, so the
# host closure is byte-identical whether or not the VM exists.
let
  inherit (lib) mkOption types;
  cfg = config.vm;

  apps = lib.optionals (config ? webStack) (config.webStack.tunnel.apps ++ config.webStack.nginx.apps);
  domains =
    map (a: a.domain) apps
    ++ lib.optionals (config ? webStack) (lib.attrNames config.webStack.nginx.redirects);

  # A host that serves nothing has no manager account either: that user comes
  # from the profile such a host does not import. This has to gate the
  # attribute, not sit inside it -- `users.users.x = mkIf false {}` still
  # creates the name.
  servesApps = apps != [ ];
  manager = if config ? webStack then config.webStack.manager else "";

  portOf = domain: cfg.portBase + (lib.lists.findFirstIndex (d: d == domain) 0 domains);

  # A VM has no DNS, so one port per vhost is what makes them reachable.
  plainVHost = domain: {
    enableACME = lib.mkForce false;
    forceSSL = lib.mkForce false;
    addSSL = lib.mkForce false;
    onlySSL = lib.mkForce false;
    useACMEHost = lib.mkForce null;
    listen = lib.mkForce [
      {
        addr = "0.0.0.0";
        port = portOf domain;
      }
    ];
  };

  secrets = if config ? age then config.age.secrets else { };
in
{
  options.vm = {
    portBase = mkOption {
      type = types.port;
      default = 8080;
      description = ''
        First guest-side nginx port. One port per vhost, assigned in
        declaration order. The host side moves separately, in run-<host>-vm.
      '';
    };

    password = mkOption {
      type = types.str;
      default = "dev";
      example = "hunter2";
      description = ''
        Console password for root and for the web stack manager inside the VM.
        The real hashes come from agenix, which a VM cannot decrypt, so without
        this there is no way in.
      '';
    };

    secretValues = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        myapp-env = "MYAPP_PGPASS=test";
        myapp-db-password = "test";
      };
      description = ''
        Test contents for named agenix secrets inside the VM. A secret not
        named here gets an empty file, which is what most consumers want.

        Name the ones whose consumer rejects an empty value -- a passwordFile
        does, deliberately, because an empty password means "clear it". A role
        password usually has to be named twice, once for the .age the database
        reconciles from and once inside the environmentFile the app reads, or
        the app sends a password the cluster does not have.

        **Never a real secret.** These land in the nix store, world-readable.
      '';
    };
  };

  config.virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 16384;
      graphics = false;
      # Forwarding is not baked in: run-<host>-vm builds QEMU_NET_OPTS instead,
      # so the host side can move when a port is already taken.
    };

    services.nginx.virtualHosts = lib.genAttrs domains plainVHost;
    security.acme.certs = lib.mkForce { };

    # The real hosts only open 22, 80 and 443, so without this the forwarded
    # ports reach a running nginx and get dropped by the firewall.
    networking.firewall.allowedTCPPorts = map portOf domains;

    # Secrets are encrypted to the real hosts' keys, so a VM cannot open them.
    system.activationScripts = {
      agenixNewGeneration = lib.mkForce "";
      agenixChown = lib.mkForce "";
      agenixInstall = lib.mkForce ''
        mkdir -p /run/agenix
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: s: ''
            printf '%s' ${lib.escapeShellArg (cfg.secretValues.${name} or "")} > ${s.path}
            chmod 0444 ${s.path}
          '') secrets
        )}
      '';
    };

    users.users = {
      root.initialPassword = cfg.password;
    } // lib.optionalAttrs (servesApps && manager != "") {
      ${manager} = {
        hashedPasswordFile = lib.mkForce null;
        initialPassword = cfg.password;
      };
    };
  };
}
