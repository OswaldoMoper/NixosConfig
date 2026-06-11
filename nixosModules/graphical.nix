{ config, pkgs, lib, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.graphical;
  isWSL = cfg.mode == "WSL";
  isGraphical = cfg.mode == "Linux";
in
{
  options.graphical = {
    enable = mkEnableOption "Graphical environment";
    mode = mkOption {
      type = types.enum [ "WSL" "Linux" ];
      default = "Linux";
      description = "Graphical mode: WSL or Linux";
    };
    keymap = mkOption {
      type = types.str;
      default = "us";
      description = "Keyboard layout";
    };
    variant = mkOption {
      type = types.str;
      default = "altgr-intl";
      description = "Keyboard layout variant";
    };
    fonts = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Fonts to install";
    };
    vscode.enable = mkOption {
      type = types.bool;
      default = config.graphical.mode == "WSL";
      description = "Enable VScode Remote integration";
    };
  };
  config = mkIf cfg.enable {
    services = {
      xserver = {
        enable = isGraphical;
        xkb = {
          layout = cfg.keymap;
          variant = cfg.variant;
        };
      };
      displayManager = {
        sddm = {
          enable = isGraphical;
          wayland.enable = isGraphical;
        };
        defaultSession = "plasma";
      };
      desktopManager.plasma6.enable = isGraphical;
    };
    programs.nix-ld.enable = cfg.vscode.enable;
    fonts.packages = mkIf isGraphical (map (f: pkgs.${f}) cfg.fonts);
    services.pipewire = {
      enable = isGraphical;
      alsa.enable = isGraphical;
      pulse.enable = isGraphical;
      jack.enable = isGraphical;
    };
  };
}