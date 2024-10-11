<h1 align=center>
  NixOS-WSL config<br />
  <a href="https://github.com/NixOS/nixpkgs/tree/nixos-24.05"><img src="https://img.shields.io/badge/nixpkgs-24.05-brightgreen" alt="nixpkgs 24.05" /></a>
</h1>

Modules for running NixOS on the Windows Subsystem for Linux

[Documentation is available here](https://nix-community.github.io/NixOS-WSL)

## Quick Start

1. Enable WSL if you haven't done already:

- ```powershell
  wsl --install --no-distribution
  ```

2. Download `nixos-wsl.tar.gz` from [the latest release](https://github.com/nix-community/NixOS-WSL/releases/latest).

3. Import the tarball into WSL:

- ```powershell
  wsl --import NixOS --version 2 $env:USERPROFILE\NixOS\ nixos-wsl.tar.gz
  ```

4. You can now run NixOS:

- ```powershell
  wsl -d NixOS
  ```

For more detailed instructions, [refer to the documentation](https://nix-community.github.io/NixOS-WSL/install.html).

## More

For the complete documentation, license and other details see [NixOS-WSL](https://github.com/nix-community/NixOS-WSL)
