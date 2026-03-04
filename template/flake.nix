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
          # `nix run` executes simulation.py inside the EMerge virtualenv with all
          # required environment variables (OpenGL, Qt, MKL) pre-set.
          packages.default = pkgs.writeShellScriptBin "run-simulation" ''
            exec ${lib.getExe self'.packages.run-emerge-simulation} ${./simulation.py} "$@"
          '';

          # --- Customisation options ---------------------------------------------------

          # Add packages that are already in EMerge's lockfile to the virtualenv.
          # Keys are package names from uv.lock; values are lists of optional extras.
          # emerge.extraDeps = {
          #   "matplotlib" = [ ];
          #   "scipy" = [ ];
          #   "some-package" = [ "extra" ];
          # };

          # Inject Python packages that are NOT in EMerge's lockfile.
          # After adding a package here, also list it in extraDeps to include it in
          # the venv.
          # emerge.pythonOverlay = final: prev: {
          #   my-package = final.callPackage ./my-package.nix { };
          # };

          # Add extra programs (not Python libraries) to devShells.default.
          # emerge.extraPackages = [ pkgs.ripgrep pkgs.gnuplot ];
        };
    };
}
