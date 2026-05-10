{ config, pkgs, lib, options, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types mapAttrs optionalString concatStringsSep recursiveUpdate;
in
{
  options.myUsers = mkOption {
    type = types.attrsOf (types.submodule({ name, ...}: {
      options = {
        native = mkOption {
          type = types.submodule {
            freeformType = types.attrsOf types.unspecified;
          };
          default = {};
          description = "Natives options of NixOS users.users";
        };

        enable = mkEnableOption "Enable this user";
        email = mkOption {
          type = types.str;
          default = "";
          description = "General email for this user (used as default for Git and msmtp)";
        };
        home = {
          enable = mkEnableOption "Enable Home Manager for this user";
          profiles = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Home Manager profiles to import";
          };
          git = {
            enable = mkEnableOption "Enable Git configuration";
            email = mkOption {
              type = types.str;
              default = config.myUsers.${name}.email;
              description = "Email for Git commits";
            };
            tag = mkOption{
              type = types.str;
              default = "";
              description = "GitHub username";
            };
          };
          msmtp = {
            enable = mkEnableOption "Enable msmtp";
            email = mkOption {
              type = types.str;
              default =  config.myUsers.${name}.email;
              description = "Email for msmtp outgoing mail";
            };
            passwordFile = mkOption {
              type = types.str;
              default = "";
              description = "Path to password file";
            };
          };
          sshKeys = {
            enable = mkEnableOption "Enable SSH key auto-loading";
            baseName = {
              enable = mkEnableOption "Enable basename keys";
              name = mkOption {
                type = types.str;
                default = "";
                description = "Base name for SSH keys";
              };
            };
            names = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "SSH key names for auto-loading";
            };
          };
          vscode.enable = mkEnableOption "Enable VScode Remote integration";
        };
      };
    }));
    default = {};
  };
  config = {
    users.users = mapAttrs (name: cfg:
      mkIf cfg.enable (
        recursiveUpdate {
        isNormalUser = true;
        shell = pkgs.zsh;
      } cfg.native
      )
    ) config.myUsers;
    programs = {
      nix-index.enableZshIntegration = true;
      zsh = {
        enable = true;
        enableCompletion = true;
        autosuggestions.enable = true;
        syntaxHighlighting.enable = true;
        ohMyZsh.enable = true;
        ohMyZsh.plugins = [ "git" "sudo" "colorize" "extract" "history" "postgres" ];
        ohMyZsh.theme = "bira";
        shellInit = ''
          NAME=$USER
          echo "welcome to NixOS, $NAME"

          if [ ! ~/.zshrc ]; then
            echo "creating ~/.zshrc"
            touch ~/.zshrc
          fi

          eval "$(direnv hook zsh)"
        '';
        promptInit = ''
          any-nix-shell zsh --info-right | source /dev/stdin
        '';
      };
      nix-ld.enable = true;
    };
    home-manager.users = mapAttrs (name: cfg: mkIf cfg.home.enable {
      home.stateVersion = "25.11";
      services.ssh-agent.enable = cfg.home.sshKeys.enable;
      programs.git = mkIf cfg.home.git.enable {
        enable = true;
        settings.user = {
          name = cfg.home.git.tag;
          email = cfg.home.git.email;
        };
      };
      home.file.".config/msmtp/config" = mkIf cfg.home.msmtp.enable {
        text = ''
          defaults
          auth           on
          tls            on
          tls_trust_file /etc/ssl/certs/ca-certificates.crt

          account default
          host smtp.gmail.com
          port 587
          from ${cfg.home.msmtp.email}
          user ${cfg.home.msmtp.email}
          passwordeval "cat ${cfg.home.msmtp.passwordFile}"
        '';
      };
      home.packages = mkIf cfg.home.msmtp.enable [
        pkgs.msmtp
      ];
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        matchBlocks."*" = {
          extraOptions = {
            "AddKeysToAgent" = "yes";
          };
          identityFile = [
            "~/.ssh/${cfg.home.sshKeys.baseName.name}_ed25519"
            "~/.ssh/${cfg.home.sshKeys.baseName.name}"
            "~/.ssh/${cfg.home.sshKeys.baseName.name}_rsa"
          ] ++ (map (key: "~/.ssh/${key}") cfg.home.sshKeys.names);
        };
      };
      programs.vscode.enable = cfg.home.vscode.enable;
      imports =
        let
          base = ./hmProfiles;
          existing = builtins.filter
            (p: builtins.pathExists (base + "/${p}.nix"))
            cfg.home.profiles;
        in
        map (p: base + "/${p}.nix") existing;
    }) config.myUsers;
  };
}