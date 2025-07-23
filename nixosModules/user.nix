{ pkgs, ... }:

let
  tagName = "OswaldoMoper";
in {
  # Define a user account.
  users.users.omoper = {
    isNormalUser = true;
    description = "Oswaldo Moper";
    extraGroups = [ "networkmanager" "wheel" "video" "audio" ];
    # Declare a password it's not necessary in WSL 
    # hashedPassword = "$6$IqhGanTrCJ3Y8GMS$2.q7j7DfXCbEEo1zUNkQTsSL5JuPpZbM4AghPXdycMBL6Hond51SCECELA7ufpbdrlq/u5UY/91Ph4Pu5Q/GW.";
    shell = pkgs.zsh;
  };
# List programs that you want to enable:
  programs = {
  # Setup VSCode Remote
    nix-ld = {
      enable = true;
      package = pkgs.nix-ld-rs;
    };
  # Enable and config Zsh
    nix-index.enableZshIntegration = true;
    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      ohMyZsh.enable = true;
      ohMyZsh.plugins = ["git" "sudo" "colorize" "extract" "history" "postgres"];
      ohMyZsh.theme = "bira";
      shellInit = ''
      NAME=${tagName}
      echo "welcome to NixOS, $NAME"

      if [ ! ~/.zshrc ]; then
        echo "creating ~/.zshrc"
        touch ~/.zshrc
      fi

      REPO_PATH="/etc/nixos"
      REPO_URL="$NAME/NixosConfig.git"
      REPO_CO="spartanWSL"
      if [ ! -d "$REPO_PATH/.git" ]; then
          echo "Configuring the $REPO_PATH directory"
          sudo rm -rf "$REPO_PATH"
          sudo git clone --recursive https://github.com/"$REPO_URL" "$REPO_PATH"
          sudo chmod -R u+w "$REPO_PATH"
          sudo chown -R omoper:users "$REPO_PATH"
          cd "$REPO_PATH"
          if ! git config --global --get-all safe.directory | grep -q "$REPO_PATH"; then
            git config --global --add safe.directory "$REPO_PATH"
          fi
          git checkout "$REPO_CO"
          git remote set-url origin git@github.com:"$REPO_URL"
      fi

      if [ ! -S ~/.ssh/ssh_auth_sock ]; then
        echo  "'ssh-agent' has not been started since the last reboot." \
              "Starting 'ssh-agent' now."
        eval "$(ssh-agent)"
        ln -sf "$SSH_AUTH_SOCK" ~/.ssh/ssh_auth_sock
      fi
      export SSH_AUTH_SOCK=~/.ssh/ssh_auth_sock
      ssh-add ~/.ssh/"$NAME"_ed25519
      ssh-add ~/.ssh/"$NAME"
      ssh-add ~/.ssh/"$NAME"_rsa
      # ssh-add ~/.ssh/id_rsa
      if [ "$?" -ne "0" ]; then
        echo  "No ssh keys have been added to your 'ssh-agent'" \
              "since the last reboot. Adding default keys now."
        ssh-add
      fi

      eval "$(direnv hook zsh)"
    '';
      promptInit = ''
        any-nix-shell zsh --info-right | source /dev/stdin
      '';
      };
  # Enable and config msmtp
    msmtp = {
      enable = true;
      accounts.default = {
        tls  = true;
        auth = true;
        # auth = "SCRAM-SHA-256";
        host = "smtp.gmail.com";
        port = 587;
        from = "omoper@example.com";
        user = "omoper@example.com";
        passwordeval = "cat /home/omoper/password.txt";
      };
    };
  # Enable and config git
    git = {
      enable = true;
      config = {
        user = {
          name = tagName;
          email = "omoper@example.com";
        };
      };
    };
  };

}