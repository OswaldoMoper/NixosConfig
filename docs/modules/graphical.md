# graphical — Graphical Environment Module

This module provides a unified interface for enabling graphical environments across different types of hosts. It abstracts the differences between native Linux systems and WSL-based systems, allowing each host to declare only the desired mode.

## Purpose

- Provide a single entry point for enabling graphical environments
- Support both native Linux desktops and WSL environments
- Avoid duplicating graphical configuration across hosts
- Allow per-host customization of keyboard layout and fonts

This module is imported by all hosts, but only activates when `graphical.enable = true`.

## Modes

### `WSL`

Designed for Windows Subsystem for Linux:

- Does **not** enable X11 or Wayland
- Does **not** enable SDDM or Plasma
- Integrates with Windows graphical stack
- Minimal overhead

Use this mode when running NixOS inside WSL.

### `Linux`

Full graphical environment for native Linux systems:

- Enables X11 (`services.xserver.enable = true`)
- Configures keyboard layout and variant
- Enables SDDM display manager
- Enables Plasma 6 desktop environment
- Enables Pipewire (ALSA, PulseAudio, JACK)
- Installs fonts declared in `graphical.fonts`

Use this mode for laptops, desktops, or servers with a GUI.

## Options

### `graphical.enable`

Enables the graphical module. If `false`, no graphical services are configured.

### `graphical.mode`

Determines the graphical environment type.

```text
"WSL" | "Linux"
```

Defaults to `"Linux"`.

### `graphical.keymap`

Keyboard layout (XKB layout). Defaults to `"us"`.

### `graphical.variant`

Keyboard layout variant. Defaults to `"altgr-intl"`.

### `graphical.fonts`

List of font package names to install.

Example:

```nix
graphical.fonts = [ "hack-font" "noto-fonts" ];
```

### `graphical.nixLd.enable`

Runs unpatched dynamically linked binaries, which is what a remote editor's server is. Defaults to `mode == "WSL"`, where one usually follows.

```Nix
graphical.nixLd.enable = true;
```

**It is the one option here that a headless host can use.** Everything else in this module sits behind `mkIf graphical.enable`; this does not, deliberately — a headless server is exactly where a remote editor matters, and it is the one host that never enables a graphical environment.

For a `code` command usable from an ordinary ssh session, that is [`vscode.nix`](./vscode.md), a separate module.

## Behavior Summary

| Mode   | X11 | SDDM | Plasma | Pipewire | Fonts | Keyboard | nix-ld |
|--------|-----|------|--------|----------|-------|----------|--------|
| WSL    | ❌  | ❌   | ❌     | ❌       | ❌    | ❌       |  ✔️    |
| Linux  | ✔️  | ✔️   | ✔️     | ✔️       | ✔️    | ✔️       |  ❌    |

`graphical.fonts`, `keymap` and `variant` are consumed inside `services.xserver` and a `mkIf isGraphical`, so under `mode = "WSL"` they accept a value and do nothing. The fonts that do reach a WSL host come from `common.nix`, not from here.

The last column is `graphical.nixLd.enable`, and it is the only one that reaches a host with `graphical.enable = false`. The rest of the table is inside `mkIf graphical.enable`.

## Examples

### Minimal WSL configuration

```nix
{pkgs, ...}: {
  # ... other host configurations ...
  graphical = {
    enable = true;
    mode = "WSL";
  };
  # ... other host configurations ...
}
```

### Full Linux desktop

```nix
{pkgs, ...}: {
  # ... other host configurations ...
  graphical = {
    enable = true;
    mode = "Linux";
    keymap = "us";
    variant = "altgr-intl";
    fonts = [ "hack-font" "noto-fonts" ];
    # If a remote editor is going to attach to this host
    # nixLd.enable = true;
  };
  # ... other host configurations ...
}
```

## When to use this module

Use it when:

- A host needs a graphical environment
- You want consistent configuration across machines
- You want to avoid duplicating X11/Plasma/SDDM setup

Do not use it for:

- Containers
- Machines that want no desktop at all

**A headless server is the exception**, and the only one: `graphical.nixLd.enable` lives outside `mkIf graphical.enable`, so a host with `graphical.enable = false` can still turn nix-ld on — which is what VS Code Remote-SSH needs, and nothing else here comes with it.

It only ever turns nix-ld **on**. An enable-shaped option that also asserted `false` would collide with any other module that wanted it, and the host would stop evaluating.

For a `code` command usable from an ordinary ssh session, see [`vscode.nix`](./vscode.md).

## Notes

- This module does **not** install X servers for WSL.
- It assumes Plasma 6 as the default desktop environment.
- Fonts must be provided as package names available in `pkgs`.
