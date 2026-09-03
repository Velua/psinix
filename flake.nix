{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.sops-nix.url = "github:Mic92/sops-nix";
  inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";

  inputs.psibase-nix.url = "github:gofractally/psibase-nix";
  inputs.psibase-nix.inputs.nixpkgs.follows = "nixpkgs";
  # Override psibase-nix's locked tarball. Change this URL, then
  # `nix flake update psibase` — no psibase-nix commit.
  # 0.28 adds `--passphrase-file` (psibase#2017). The lock still points at
  # 0.27 until that tarball is published; then update the input.
  inputs.psibase = {
    url = "https://github.com/gofractally/psibase/releases/download/v0.28.0-pre/psidk-ubuntu-2404.tar.gz";
    flake = false;
  };
  inputs.psibase-nix.inputs.psibase.follows = "psibase";

  outputs = {
    nixpkgs,
    disko,
    sops-nix,
    nixpkgs-unstable,
    psibase-nix,
    ...
  }: {
    nixosConfigurations.generic = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        unstable = nixpkgs-unstable;
      };
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        psibase-nix.nixosModules.psibase
        ./configuration.nix
        ./hardware-configuration.nix
      ];
    };
  };
}
