{
  description = "oswaldo's system config";
  inputs.nix.url = "github:nixos/nix/master";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  # inputs.simple-nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-23.11";

  outputs = inputs@ { self
                    , nixpkgs
                    , nixos-hardware
                    # , simple-nixos-mailserver
                    , ... }:
  {
    nixosConfigurations = {
      spartan = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (import ./configuration.nix)
          # simple-nixos-mailserver.nixosModule
          # {
          #   mailserver = {
          #     enable = true;
          #     fqdn = "smtp.gmail.com";
          #     loginAccounts = {
          #       "oswaldomoyap@gmail.com" = {
          #         hashedPassword = "$2b$05$7wv1ukLN4uAADdhMBbbfI.luQHkBDmGFAnacu2PJjRMQCodeJSEqO";
          #         aliases = [ "oswaldomoyap@gmail.com" ];
          #       };
          #     };
          #     # certificateScheme = "acme-nginx";
          #   };
          #   # security.acme.acceptTerms = true;
          #   # security.acme.defaults.email = "oswaldomoyap@gmail.com";
          # }
        ];
        specialArgs = { inherit inputs; };
      };
    };
  };
}
