# sentinel — What this machine has not shown before

Once a day the machine looks at itself and mails, through [`alerts`](./alerts.md), only what is new against a list it keeps in `/var/lib/sentinel`. The first pass mails everything it sees and learns it, which is also the proof that the mail arrives.

## Usage

```nix
alerts.recipientsFile = config.age.secrets.alert-recipients.path;

sentinel = {
  enable = true;
  versioned = [ "/home/*/.vscode-server/code-*" ];   # updates itself
};
```

## Options

| Option | |
| --- | --- |
| `enable` | the daily pass. Needs `alerts.recipientsFile` |
| `at` | when it runs, as a systemd `OnCalendar` value; 08:00 in Mexico City by default. A pass missed while the machine was off runs at boot |
| `versioned` | globs of paths outside the store that update themselves. A new path matching one is learned without a mail; one already known still mails when its content changes |

## What a pass looks at

| What | Mails when |
| --- | --- |
| ssh logins accepted since the last pass | a user logs in with a key not seen for that user, or from a network not seen for that user (the /16 of an IPv4 address, the /32 of an IPv6 one) |
| the file sshd took the key from | always, when it is outside `/etc/ssh/authorized_keys.d/` |
| running processes whose binary is outside `/nix/store` | the path is new, or a known one changed content |
| loaded units whose file is outside `/nix/store` | likewise |
| executables in `/tmp`, `/var/tmp` and `/dev/shm` | likewise |
| `nix-store --verify-path` over the running system's closure | a path's content fails its hash |

Failed logins never mail. A path is known by its exact name, and its content by its sha256.

sshd names the file a key came from only at `LogLevel VERBOSE`, so the module sets it with `lib.mkDefault`, as `fail2ban` does; a host that sets another level wins, and loses that line.

The pass learns what it reported only once the mail went out, so a mail that fails is sent again the next day. It runs as root, at the lowest CPU and disk priority; on a server with a 7.6 GiB closure the verification took 40 s.

## Testing

`tests/sentinel.sh` runs the pass against a fake journal, `systemctl`, `nix-store` and mail, over a fake `/proc` and temporary directories, day after day on one state directory; `nix flake check` runs it.

`tests/sentinel-vm.nix` boots a machine with a real sshd and journal, logs in, and checks what each pass mails. It is not a check, since without KVM it takes 15–20 minutes; run it when `sentinel` changes, with `nix build .#sentinel-vm-test`.
