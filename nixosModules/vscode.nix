{ config, pkgs, lib, ... }:

let
  inherit (lib) mkIf mkEnableOption;
  cfg = config.vscode.remoteCli;

  code = pkgs.writeShellApplication {
    name = "code";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = ''
      uid="$(id -u)"
      sock="$(find "/run/user/$uid" -maxdepth 1 -name 'vscode-ipc-*.sock' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
      if [ -z "$sock" ]; then
        echo "code: no VS Code is connected to this machine as $(id -un)." >&2
        echo "Open it here with Remote-SSH first; this only borrows that session." >&2
        exit 1
      fi

      cli="$(find "$HOME/.vscode-server/cli/servers" -type f \
        -path '*/server/bin/remote-cli/code' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
      if [ -z "$cli" ]; then
        echo "code: a session is open but no server CLI is unpacked under ~/.vscode-server." >&2
        exit 1
      fi

      VSCODE_IPC_HOOK_CLI="$sock" exec "$cli" "$@"
    '';
  };
in
{
  options.vscode.remoteCli.enable = mkEnableOption ''
    a `code` command that works from any shell on this machine, not only
    from the terminal VS Code opens itself. Leave it off where a `code`
    already exists -- under WSL the Windows side supplies one'';

  config = mkIf cfg.enable {
    environment.systemPackages = [ code ];
  };
}
