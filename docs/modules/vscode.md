# vscode — `code .` from an ordinary ssh shell

Provides a `code` command that works from **any** shell on the machine, not only from the terminal VS Code opens for itself.

## The gap it closes

VS Code Remote-SSH already works on a NixOS host, provided `programs.nix-ld.enable` is on — that is what lets the prebuilt `node` it downloads actually run. Nothing else is needed for the editor itself.

What does not work is `code .` from a plain `ssh` session. VS Code injects its own `code` wrapper and the `VSCODE_IPC_HOOK_CLI` variable **only into the terminal it opens**. From any other shell the IPC socket is sitting right there in `/run/user/$UID/` with nothing pointing at it.

This module points at it.

## Options

### `vscode.remoteCli.enable`

Off by default.

```Nix
vscode.remoteCli.enable = true;
```

> **Leave it off wherever a `code` already exists.** Under WSL the Windows side supplies one, and two `code` commands on the same `PATH` is a coin flip.

## How it works

1. Find the newest `/run/user/$UID/vscode-ipc-*.sock`
2. Find the newest `~/.vscode-server/cli/servers/*/server/bin/remote-cli/code`
3. `exec` the second with `VSCODE_IPC_HOOK_CLI` set to the first

Both steps take the **newest** match rather than the first: server versions accumulate under `~/.vscode-server`, and a machine can easily hold half a dozen.

## When it cannot work, it says so

| Situation | What you get |
| --- | --- |
| No VS Code connected as you | `no VS Code is connected to this machine as <user>` |
| Connected, but no server CLI unpacked | `a session is open but no server CLI is unpacked under ~/.vscode-server` |

Neither is an error you have to interpret. The first one means: open the machine with Remote-SSH first — this only borrows that session, it cannot create one.

## An implementation note worth keeping

Both `find` calls end in `|| true`, and that is load-bearing rather than defensive. The script is packaged with `writeShellApplication`, so it runs under `set -euo pipefail`; `find` exits 1 on a directory that does not exist, `pipefail` propagates it, and `set -e` would then kill the script **with no output at all** — swallowing the very messages above.

## Housekeeping

`~/.vscode-server` grows without bound: every server version the editor has ever installed on that host stays. Several gigabytes is normal after a year. Removing the old ones is safe; removing all of them just makes the next connection download one again.
