{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.sops-nix.url = "github:Mic92/sops-nix";
  inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";

  # Until the nix module lands on main: PR #1953
  inputs.psibase.url = "github:gofractally/psibase?ref=refs/pull/1953/head";

  outputs = {
    nixpkgs,
    disko,
    sops-nix,
    nixpkgs-unstable,
    psibase,
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
        psibase.nixosModules.psibase
        ./configuration.nix
        ./hardware-configuration.nix
      ];
    };
  };
}
