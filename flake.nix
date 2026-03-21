{
  description = "EMerge Python Library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    emerge-src = {
      url = "github:FennisRobert/EMerge";
      flake = false;
    };
    suitesparse-src = {
      url = "github:DrTimothyAldenDavis/SuiteSparse/v7.12.2";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./module.nix ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        flakeModules.default = ./module.nix;
        templates.default = {
          path = ./template;
          description = "EMerge EM simulation starter";
        };
      };

      perSystem =
        {
          config,
          self',
          pkgs,
          ...
        }:
        {
          packages.suitesparse = pkgs.callPackage ./suitesparse.nix {
            src = inputs.suitesparse-src;
          };

          emerge.suitesparse = self'.packages.suitesparse;

          packages.default = config.packages.emerge;

          formatter = pkgs.nixfmt-tree;
        };
    };
}
