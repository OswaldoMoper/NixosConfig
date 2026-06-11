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

### `graphical.vscode.enable`

Enables VSCode Remote integration via nix-ld. (`true` by default in mode `WSL`)

```Nix
graphical.vscode.enable = true;
```

## Behavior Summary

| Mode   | X11 | SDDM | Plasma | Pipewire | Fonts | Keyboard | VSCode |
|--------|-----|------|--------|----------|-------|----------|--------|
| WSL    | ❌  | ❌   | ❌     | ❌       | ✔️    | ✔️       |  ✔️    |
| Linux  | ✔️  | ✔️   | ✔️     | ✔️       | ✔️    | ✔️       |  ✔️    |

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
    # If you want to remote code via vscode
    # vscode.enable = true;
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

- Headless servers
- Containers
- Remote-only machines

Except when this needs remote code via vscode.

## Notes

- This module does **not** install X servers for WSL.
- It assumes Plasma 6 as the default desktop environment.
- Fonts must be provided as package names available in `pkgs`.
