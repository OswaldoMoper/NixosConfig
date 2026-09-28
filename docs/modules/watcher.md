# watcher — Is the site up, and which part of it is not

This module watches names the way a visitor would, through [cattleServer](https://github.com/OswaldoMoper/cattleServer): each pass asks the name over https, asks the origin at `machineAddress`, and says which of the two failed — the registrar, the DNS, the edge in front of the machine, or the machine itself. A certificate that is about to expire counts as a failure too.

It stands on its own, the way `postgresql` does: any host can watch any name. [`webStack`](./webstack.md) adds every name it serves, the way it adds its databases to `postgresql.ensure`, so a name given to an app is watched without being listed twice.

## Usage

```nix
imports = [ inputs.cattleServer.nixosModules.default ];

watcher = {
  enable = true;
  hostAddresses = [ "203.0.113.10" ];
  sites."status.example.org" = { };         # one webStack does not serve
  sites."example.net".proxied = true;       # behind a proxy: resolves elsewhere
  alert = {
    recipientsFile = config.age.secrets.watcher-recipients.path;  # "Bcc: a@example.org, b@example.org"
    passwordFile = config.age.secrets.smtp-password.path;
  };
};
```

## Options

| Option | |
| --- | --- |
| `enable` | turns the watch on. The names webStack writes count only then |
| `sites.<name>` | a name to watch. Declaring it is enough: `{ }` |
| `sites.<name>.enable` | `false` leaves out a name something else declared, such as one of webStack's |
| `sites.<name>.proxied` | the name resolves to a proxy rather than to this machine, so it is not held to `hostAddresses` |
| `hostAddresses` | what every name that is not proxied must resolve to. Empty accepts any, which leaves a name pointed somewhere else unnoticed |
| `machineAddress` | the origin asked over plain http when a name fails, to tell the name from the machine. `127.0.0.1` by default, which is right only when the watcher runs on the machine it watches |
| `controls` | URLs of sites that are not watched, asked first. When none answers, the pass logs `Cannot look`, judges nothing and leaves every count of bad checks alone. Empty by default; set, it needs a cattleServer that knows `controls` |
| `alert.recipientsFile` | a file of mail headers naming who is alerted, and nothing else. With it the module writes the alert command itself, through the system's msmtp account |
| `alert.passwordFile` | the SMTP password for that account, when the one in its configuration is not readable by the service user |
| `settingsFile` | a secret holding cattleServer's whole configuration, for a watch whose names and addresses are secret too. Replaces every option above and `services.cattleServer.settings`; see below |
| `alertCommand` | any other shell command, run once a name has failed its checks, with the detail on standard input. Null only logs. Excludes `alert.recipientsFile` |

## Who is alerted, and why the list is a file

The recipients are read when an alert goes out, not when the configuration is built, so the list can be a secret instead of sitting in the store where every user can read it — and adding a recipient is an edit of that secret, not of the host. The file holds headers, one or more, such as `Bcc: a@example.org, b@example.org`; `To:` and `Cc:` work as well. msmtp takes the recipients from them and replaces them with `To: undisclosed-recipients:;`, so nobody who receives an alert learns who else did.

The subject names the machine that looked, then the URL and the verdict (`[watcher-host] https://example.org: name-does-not-resolve`), so two watchers on the same names can be told apart; the body is the detail. It has to be readable by `services.cattleServer.user`, which is what the service runs as.

`sites` is an ordinary typed option, so it merges and overrides the NixOS way: a host adds to what webStack wrote, `sites."x".enable = false` removes one, and `lib.mkForce { … }` replaces the lot. A misspelt name in `sites` is not silently ignored: it becomes a name of its own, which fails to resolve on the first pass and says so.

The cadence is cattleServer's own, `services.cattleServer.settings.checkEvery`, and so is how many consecutive failures raise an alert.

## The whole watch as a secret

`settingsFile` hands cattleServer a configuration that never enters the store, through its own `services.cattleServer.settingsFile`, which arrives as a systemd credential. Everything the other options would render goes inside it — the sites, the addresses, `controls`, the cadence and the alert command — so they must be left unset, and an assertion says so. A webStack app on the same host adds its names to `sites`, which trips that assertion: such a host watches with the ordinary options.

The alert command inside the file calls `msmtp`, `sed` and `cat` **by name**, and the module puts them on the unit's `PATH`. A store path written into a secret keeps nothing alive, so after the next collection the command would point at nothing and the alert would fail at the one moment it matters. The mail account can travel the same way, as an `msmtprc` passed with `msmtp -C`.

The file is best produced rather than written: declare the watch with the ordinary options on a scratch copy of the host, read `services.cattleServer.settings` as JSON, point its `alertCommand` at bare names, and encrypt the result.

## This library does not bring cattleServer

The module writes `services.cattleServer`, the option the host provides by importing cattleServer's module, and an assertion says so when the import is missing. Taking cattleServer as an input here would put its build — haskell.nix, import from derivation — into the lock of every consumer of this library, most of which watch nothing.

Both halves are guarded the same way: `watcher` writes to cattleServer only where its module is imported, and `webStack` writes to `watcher.sites` only where this one is.

## What it cannot see

Run on the machine it watches, it cannot report that machine being down: that takes a second watcher somewhere else, with `machineAddress` set to the watched machine and, on a machine that loses its own network, `controls` — without them a laptop that goes offline blames every site at once. A watcher that is switched off watches nothing and says nothing. And the origin is asked over plain http at `machineAddress` — a certificate is issued to the name, never to the address — so a machine that serves only 443 is reported as not answering.
