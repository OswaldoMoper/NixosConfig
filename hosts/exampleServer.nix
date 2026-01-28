{ pkgs, self, deploy-rs, inputs, ... }:

{
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
        static = "/home/example/nixTalk/static";
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
    ];
  };
  # Dummy deploy.nodes
  deploy.nodes.exampleServer = {
    hostname = "0.0.0.0";
    fastConnection = false;
    profiles.system = {
      sshUser = "example";
      path = deploy-rs.lib.activate.nixos self.nixosConfigurations.exampleServer;
      user = "root";
    };
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
  ];

}