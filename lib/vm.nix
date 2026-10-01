{ lib }:

{
  # One `run-<host>-vm` per host, wrapping NixOS's own VM runner with the port
  # forwarding its vmVariant implies.
  mkVmApps =
    { pkgs, nixosConfigurations }:
    let
      runner =
        name: hostConfig:
        let
          vhosts = hostConfig.config.virtualisation.vmVariant.services.nginx.virtualHosts;
          guestPort = domain: (lib.head vhosts.${domain}.listen).port;
          domains = lib.sort (a: b: guestPort a < guestPort b) (lib.attrNames vhosts);
          first = guestPort (lib.head domains);
        in
        pkgs.writeShellApplication {
          name = "run-${name}-vm";
          text = ''
            base=''${VM_PORT_BASE:-18080}
            if [ "''${1:-}" = "--port-base" ]; then
              [ $# -ge 2 ] || { echo "--port-base needs a number" >&2; exit 1; }
              base=$2; shift 2
            fi

            fwd=""
            ${lib.concatMapStringsSep "\n" (d: ''
              printf '  %-26s http://localhost:%s\n' ${lib.escapeShellArg d} \
                "$((base + ${toString (guestPort d - first)}))"
              fwd="$fwd,hostfwd=tcp::$((base + ${toString (guestPort d - first)}))-:${toString (guestPort d)}"
            '') domains}
            printf '  %-26s ssh -p %s root@localhost\n' "(the machine)" \
              "$((base + ${toString (lib.length domains)}))"
            fwd="$fwd,hostfwd=tcp::$((base + ${toString (lib.length domains)}))-:22"
            echo

            export QEMU_NET_OPTS="''${QEMU_NET_OPTS:+''${QEMU_NET_OPTS},}''${fwd#,}"
            exec ${lib.getExe hostConfig.config.system.build.vm} "$@"
          '';
        };
    in
    lib.mapAttrs' (
      name: hostConfig:
      lib.nameValuePair "run-${name}-vm" {
        type = "app";
        program = lib.getExe (runner name hostConfig);
      }
    )
      (lib.filterAttrs (_: h: h.config.system.build ? initialRamdisk) nixosConfigurations);
}
