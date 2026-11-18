# Evaluates an app's rateLimit through webStack's own type, and checks what a
# limit's kind fills in, what a value set by hand keeps, and what still has to
# be set.
{ pkgs }:

let
  inherit (pkgs) lib;
  ws = import ../nixosModules/webstack/lib.nix { inherit lib pkgs; };

  limits = rateLimit: (lib.evalModules {
    modules = [
      { options.app = lib.mkOption { type = ws.webApp; }; }
      { app.rateLimit = rateLimit; }
    ];
  }).config.app.rateLimit;

  numbers = limit: { inherit (limit) perMinute burst; };
  evaluates = rateLimit: (builtins.tryEval (builtins.deepSeq (lib.mapAttrs (_: numbers) (limits rateLimit)) true)).success;

  route = { paths = [ "/a" ]; methods = [ "POST" ]; };
  mail = limits { send = route // { kind = "mail"; }; };
  rendered = ws.rateLimitHttpConfig [ { name = "t"; rateLimit = mail; } ];
  located = ws.rateLimitRoutes { name = "t"; rateLimit = mail; };

  cases = {
    "kind mail gives 1 and 3" = numbers mail.send == { perMinute = 1; burst = 3; };
    "kind login gives 30 and 20" =
      numbers (limits { signin = route // { kind = "login"; }; }).signin == { perMinute = 30; burst = 20; };
    "a number set by hand wins over the kind" =
      numbers (limits { send = route // { kind = "mail"; burst = 5; }; }).send == { perMinute = 1; burst = 5; };
    "without a kind, the numbers set by hand are kept" =
      numbers (limits { x = route // { perMinute = 7; burst = 2; }; }).x == { perMinute = 7; burst = 2; };
    "without a kind or numbers, it does not evaluate" = !evaluates { x = route; };
    "an unknown kind does not evaluate" = !evaluates { x = route // { kind = "other"; }; };
    "nginx gets the kind's rate" = lib.hasInfix "rate=1r/m;" rendered;
    "nginx gets the kind's burst" = map (r: r.burst) located == [ 3 ];
  };

  report = lib.concatStrings (lib.mapAttrsToList (name: ok: "${if ok then "ok   " else "FAIL "} ${name}\n") cases);
in
pkgs.runCommand "rate-limit-test" { inherit report; } ''
  printf '%s' "$report"
  if grep -q '^FAIL' <<< "$report"; then exit 1; fi
  touch "$out"
''
