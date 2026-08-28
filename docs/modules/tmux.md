# tmux — a which-machine-am-I cue

Enables tmux on every host and styles its status bar from a single colour.

## Purpose

`tmux.accent` is **a safety cue, not decoration**. It answers "which machine am I on" at a glance, so a command meant for a dev box is less likely to land on production.

That is the whole reason the module exists. Everything else it sets — the terminal type, the dim greys, the clock — is there so the accent is the only thing that differs between hosts, and so the difference is impossible to miss.

## Options

### `tmux.accent`

Colour of the status bar's active elements. Defaults to `#646464`, a grey that reads as "no one chose this".

```Nix
tmux.accent = "#ff5f5f";
```

It drives, all at once:

- the current window in the status bar
- the active pane border
- the message line
- the session name on the left, and the hostname on the right

The inactive parts stay grey on purpose, so the accent is the only colour on screen.

## Convention

Give every machine a different one, and pick them so that the *dangerous* box is the one that looks alarming:

| Host | Accent | |
| --- | --- | --- |
| spartanWSL | `#7fff00` green | local, nothing to lose |
| sandbox | amber | shared dev |
| prod | `#ff5f5f` red | **production** |

Nothing enforces this — no assertion checks that two hosts differ. It is a convention held up by
review, which is worth knowing before relying on it.

## Config

Applied unconditionally: there is no `enable`. A host that imports the module gets tmux, because a
box you reach over ssh and cannot leave a session on is worse than one with an extra package.

The status bar refreshes every second (`status-interval 1`), which is what makes the clock on the
right useful for spotting a hung command.
