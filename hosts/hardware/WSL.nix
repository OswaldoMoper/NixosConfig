{ ... }:

# WSL needs no hardware configuration: nixos-wsl provides the bootloader and
# the filesystems, and the VM's memory and swap are sized by .wslconfig on the
# Windows side, not from here.
#
# The file is kept, empty, so a host has somewhere to grow one and so the
# hosts/hardware/ convention holds for every machine.

{ }
