# alerts — Whom a module mails when it alerts

A host says once whom its alerts reach and with which SMTP password; every module that alerts mails through it, each with its own subject. [`watcher`](./watcher.md) is one.

## Usage

```nix
alerts = {
  recipientsFile = config.age.secrets.alert-recipients.path;  # "Bcc: a@example.org, b@example.org"
  passwordFile = config.age.secrets.smtp-password.path;
};
```

## Options

| Option | |
| --- | --- |
| `recipientsFile` | a file of mail headers naming who is alerted, and nothing else: no blank line. Null sends no mail |
| `passwordFile` | the SMTP password, when the one in the msmtp account's configuration is not readable by the alerting service. Read only with `recipientsFile` |
| `mailCommand` | read-only, for modules: given a shell command that prints the `Subject:` header and a blank line, the shell command that mails its own standard input after them |

## Why the list is a file

The recipients are read when an alert goes out, not when the configuration is built, so the list can be a secret instead of sitting in the store where every user can read it — and adding a recipient is an edit of that secret, not of the host. The file holds headers, one or more, such as `Bcc: a@example.org, b@example.org`; `To:` and `Cc:` work as well. msmtp takes the recipients from them and replaces them with `To: undisclosed-recipients:;`, so nobody who receives an alert learns who else did.

The mail goes through the system's msmtp account, which the host configures. The files have to be readable by whichever service alerts.
