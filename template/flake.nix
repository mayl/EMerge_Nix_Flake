{
  description = "EMerge EM simulation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    emerge-flake = {
      url = "github:mayl/EMerge_Nix_Flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          self',
          inputs',
          pkgs,
          lib,
          ...
        }:
        {
          packages = {
            # Run the simulation: nix run
            default = pkgs.writeShellScriptBin "run-simulation" ''
              exec ${lib.getExe inputs'.emerge-flake.packages.run-emerge-simulation} ${./simulation.py} "$@"
            '';
            inherit (inputs'.emerge-flake.packages)
              emerge-env
              emerge
              suitesparse
              run-emerge-simulation
              ;
          };

          devShells.default = inputs'.emerge-flake.devShells.default;
        };
    };
}
