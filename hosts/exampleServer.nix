# This is a configuration example of a server to be deploy
{ pkgs, self, inputs, ... }:

{
  # Dummy Hardware-configuration:
  # Use the hardware-configuration.nix gave it by nixos-generate instead of this
  # Use: imports = [./hardware/<name>.nix];
  fileSystems."/".device = "/dev/disk/by-label/nixos";
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  # Dummy user
  myUsers.example = {
    enable = true;
    fullName = "Example User";
    email = "example@mail.com";
    home = {
      msmtp = {
        enable = true;
        passwordFile = "/home/example/password.txt";
      };
    };
  };
  users.users.example.openssh.authorizedKeys.keys = [ "Copypaste your hashes" ];
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [ "@wheel" ];
  # Dummy Web Hosting Service
  webStack = {
    enable = true;
    email = "example@mail.com";
    manager = "example";
    mode = "nginx";
    apps = [
      {
        # We use nixTalk like a dummy app here
        name = "nixTalk";
        domain = "domain.com";
        port = 2000;
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
    ];
  };

  # Dummy PostgreSQL server
  postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    port = 5432;
    dumpFile = "/home/example/postgres_backup_local.sql";
    logStatements = "all";
  };
  # Graphical Environment disabled
  graphical.enable = false;
  # WSL config disabled
  wsl.enable = false;
  
  networking.firewall.allowedTCPPorts = [ 22 80 5432 ];

  environment.systemPackages = with pkgs; [
    openssh
    git
    vim
    emacs
    zsh
  ] ++ [
    self.packages.x86_64-linux.nixos-rebuild-migration
  ];
}