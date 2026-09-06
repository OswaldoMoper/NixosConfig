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
    nixLd.enable = mkOption {
      type = types.bool;
      default = config.graphical.mode == "WSL";
      description = ''
        Run unpatched dynamically linked binaries, which is what a remote
        editor's server is. Defaults on under WSL, where one usually follows.

        Deliberately outside the rest of this module's config: a headless host
        is exactly where a remote editor matters, and it is the one host that
        never enables a graphical environment.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.nixLd.enable { programs.nix-ld.enable = true; })

    (mkIf cfg.enable {
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
        defaultSession = mkIf isGraphical "plasma";
      };
      desktopManager.plasma6.enable = isGraphical;
    };
    fonts.packages = mkIf isGraphical (map (f: pkgs.${f}) cfg.fonts);
    services.pipewire = {
      enable = isGraphical;
      alsa.enable = isGraphical;
      pulse.enable = isGraphical;
      jack.enable = isGraphical;
    };
    })
  ];
}