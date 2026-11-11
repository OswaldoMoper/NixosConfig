# Evaluates watcher against a stand-in for cattleServer's module, which this
# library does not bring, and checks the assertions that guard a site's
# addresses and the alert command handed to cattleServer.
{ pkgs, nixpkgs }:

let
  inherit (pkgs) lib;

  standIn = { lib, ... }: {
    options = {
      networking.hostName = lib.mkOption { type = lib.types.str; };
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      services.cattleServer = {
        enable = lib.mkOption { type = lib.types.bool; default = false; };
        user = lib.mkOption { type = lib.types.str; default = "cattleserver"; };
        stateDir = lib.mkOption { type = lib.types.str; default = "/var/lib/cattleServer"; };
        settingsFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        settings = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      };
    };
  };

  host = module: (lib.evalModules {
    modules = [
      "${nixpkgs}/nixos/modules/misc/assertions.nix"
      standIn
      ../nixosModules/watcher.nix
      { _module.args.pkgs = pkgs; networking.hostName = "watcher-test"; watcher.enable = true; }
      module
    ];
  }).config;

  failed = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
  trips = text: module: lib.any (lib.hasInfix text) (failed (host module));

  twoMachines = {
    "a.example.org" = { };
    "b.example.org".machineAddress = "203.0.113.20";
    "c.example.org".enable = false;
  };
  own = host { watcher = { sites = twoMachines; alertCommand = "cat > /dev/null"; }; };
  mailed = host { watcher.sites = twoMachines; alerts.recipientsFile = "/run/secrets/recipients"; };
  silent = host { watcher.sites = twoMachines; };
  command = own.services.cattleServer.settings.alertCommand;

  cases = {
    "sites that are well formed trip no assertion" = failed own == [ ];
    "empty addresses trip an assertion" =
      trips "addresses is empty" { watcher.sites."a.example.org".addresses = [ ]; };
    "addresses on a proxied name trip an assertion" =
      trips "is proxied" { watcher.sites."a.example.org" = { proxied = true; addresses = [ "203.0.113.10" ]; }; };
    "a disabled name with empty addresses trips none" =
      !trips "addresses is empty" { watcher.sites."a.example.org" = { enable = false; addresses = [ ]; }; };
    "every enabled name is an app, under its dashed name" =
      map (app: app.appConfig.name) own.services.cattleServer.settings.apps
        == [ "watch-a-example-org" "watch-b-example-org" ];
    "the mail is wrapped as an alert command of its own is" =
      lib.hasInfix "-watch-alert " mailed.services.cattleServer.settings.alertCommand;
    "no command and no recipients leave the alert command null" =
      silent.services.cattleServer.settings.alertCommand == null;
  };

  report = lib.concatStrings (lib.mapAttrsToList (name: ok: "${if ok then "ok   " else "FAIL "} ${name}\n") cases);
in
pkgs.runCommand "watcher-test" { inherit report; } ''
  printf '%s' "$report"
  read -r path script machines marks window inner <<< '${command}'
  problem() { echo "FAIL  $*"; touch failed; }
  [ "$path" != "''${path#PATH=/nix/store/}" ] || problem "the command does not start by setting PATH: $path"
  grep -q 'CATTLE_APP' "$script" || problem "the first word is not watch-alert: $script"
  printf 'watch-a-example-org 127.0.0.1\nwatch-b-example-org 203.0.113.20\n' | diff - "$machines" \
    || problem "the table of machines is not one line per enabled name"
  [ "$marks" = /var/lib/cattleServer/watch-alert ] || problem "marks are not kept under the state directory: $marks"
  [ "$window" = 1800 ] || problem "the window is not 30 minutes: $window"
  grep -qF 'cat > /dev/null' "$inner" || problem "the last word does not run the alert command: $inner"
  if grep -q '^FAIL' <<< "$report" || [ -e failed ]; then exit 1; fi
  touch "$out"
''
