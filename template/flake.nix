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
      imports = [ inputs.emerge-flake.flakeModules.default ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          self',
          pkgs,
          lib,
          ...
        }:
        {
          # Run the simulation: nix run
          packages.default = pkgs.writeShellScriptBin "run-simulation" ''
            exec ${lib.getExe self'.packages.run-emerge-simulation} ${./simulation.py} "$@"
          '';

          # Uncomment to add extra packages to the Python environment:
          # emerge.pythonOverlay = final: prev: {
          #   my-package = final.callPackage ./my-package.nix { };
          # };

          # Uncomment to include extra packages in the venv:
          # emerge.extraDeps = {
          #   "extra-package" = [ ];
          # };

          # Uncomment to add extra programs to the devshell:
          # emerge.extraPackages = [ pkgs.ripgrep pkgs.jq ];
        };
    };
}
