{ config, lib, ... }:

let
  cfg = config.tmux;
in
{
  options.tmux.accent = lib.mkOption {
    type = lib.types.str;
    default = "#646464";
    example = "#ff5f5f";
    description = ''
      Colour of the tmux status bar, active window and message line.

      This is a safety cue, not decoration: it answers "which machine am I on"
      at a glance, so a command meant for a dev box is less likely to land on
      production.
    '';
  };

  config = {
    programs.tmux = {
      enable = true;
      terminal = "tmux-256color";

      extraConfig = ''
        set -as terminal-features ",*256color*:RGB"

        set -g status-style                "bg=black,fg=#646464"
        set -g window-status-style         "fg=#646464"
        set -g window-status-current-style "fg=${cfg.accent},bold"
        set -g pane-border-style           "fg=#4a4a4a"
        set -g pane-active-border-style    "fg=${cfg.accent}"
        set -g message-style               "bg=black,fg=${cfg.accent}"

        set -g status-left        "#[fg=${cfg.accent},bold][#S] "
        set -g status-left-length 20
        set -g status-right       "#[fg=${cfg.accent}]#H  #[fg=#ababab][%H:%M:%S]"
        set -g status-interval 1
      '';
    };
  };
}
