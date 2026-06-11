{config, pkgs, inputs, ...}:

{
  system.stateVersion = "26.05";
  environment.pathsToLink = [
    "/share/nix-direnv"
    "/share/zsh"
  ];
  fonts.packages = with pkgs; [
    hack-font
  ];
  services = {
    openssh.enable = true;
    sshd.enable = true;
  };
  nix = {
    settings = {
      allow-import-from-derivation = true;
      auto-optimise-store = true;
      download-buffer-size = 671088640;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
      keep-outputs = true
      keep-derivations = true
    '';
  };
  nixpkgs.config.allowUnfree = true;
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  system.configurationRevision = inputs.nixpkgs.lib.mkIf (inputs.self ? rev) inputs.self.rev;
}