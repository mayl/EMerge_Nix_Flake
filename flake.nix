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
    emsutil-src = {
      url = "github:FennisRobert/emsutil";
      flake = false;
    };
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, lib, system, ... }:
        let
          # Load the uv workspace for EMerge
          workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = inputs.emerge-src;
          };

          # Select Python interpreter matching workspace requirements (>=3.10, <4.0)
          python = lib.head (
            inputs.pyproject-nix.lib.util.filterPythonInterpreters {
              inherit (workspace) requires-python;
              inherit (pkgs) pythonInterpreters;
            }
          );

          # Create base Python package set
          pythonBase = pkgs.callPackage inputs.pyproject-nix.build.packages {
            inherit python;
          };

          # Create overlay from uv.lock
          workspaceOverlay = workspace.mkPyprojectOverlay {
            sourcePreference = "wheel";
          };

          # Compose the final Python package set
          pythonSet = pythonBase.overrideScope (
            lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.default
              workspaceOverlay
            ]
          );
        in
        {
          packages = {
            # The emerge package
            emerge = pythonSet.emerge;

            # Virtual environment for direct use
            emerge-env = pythonSet.mkVirtualEnv "emerge-env" workspace.deps.default;

            # Default output
            default = self'.packages.emerge;
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              uv
            ];
          };
        };
    };
}
