{ config, pkgs, modulesPath, ... }:

{
  swapDevices = [{
    device = "/swapfile"
    ; size = 8192;
  }];

}