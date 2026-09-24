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
        appInputs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "myApp" ];
          description = ''
            Flake inputs that are applications, which move in a deploy of their
            own. The gate compares the lock against the one of the revision the
            machine runs, and stops when one of these moved without being named
            in GATE_PIN_OK; any other input that moved is only reported.

            Empty skips the comparison.
          '';
        };
        backup = mkOption {
          default = null;
          description = ''
            A backup taken with cattleServer before this node is deployed, and
            the gate stops if it does not come back saying it recorded one.

            Null takes none, which is the state every node was in before this
            existed: the deploy goes ahead with whatever copy happens to exist.
          '';
          type = types.nullOr (types.submodule {
            options = {
              package = mkOption {
                type = types.package;
                description = ''
                  The cattleServer to run. It comes from the consumer rather
                  than from here so that a flake which does not back anything
                  up needs no such input to evaluate.
                '';
              };
              app = mkOption {
                type = types.str;
                description = "Name of the application to back up, as its configuration spells it.";
              };
              config = mkOption {
                type = types.str;
                description = "Path to the cattleServer configuration, on the machine that deploys.";
              };
            };
          });
        };
        census = mkOption {
          default = null;
          description = ''
            What to count on the machine before deploying and again after, so
            the deploy has to account for what it removed.

            It asserts that nothing disappears, and stops when something does.
            With a backup declared as well, the two losses that cannot cost
            anything are put back from it first: a database whose rowsIn tables
            all came back empty -- new, not behind -- and entries missing from
            files. A database that is behind is never replaced; the gate stops
            and prints the command that would.

            A merge of two tables into one is a legitimate way to lose a name,
            so the escape is to say which names may go, this once, in
            GATE_SHRINK_OK -- the deploy that does it is the deploy that knows.

            By name, never by total: a count cannot tell two tables merged from
            one table lost, and it is the same trap as a test suite guarded by
            how many tests it has.
          '';
          type = types.nullOr (types.submodule {
            options = {
              rowsIn = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [ "customer" ];
                description = ''
                  Tables, in the first declared database, that must not come
                  out of a deploy with fewer rows than they went in with. All
                  of them at zero is what says the database came back new.

                  Only the ones where losing rows is always wrong. A queue
                  drains as it is consumed, so listing one would stop a deploy
                  for doing its job.
                '';
              };
              files = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [ "/upload" ];
                description = "Directories whose entries are counted.";
              };
            };
          });
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