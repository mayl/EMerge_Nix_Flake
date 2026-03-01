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
              # emsutil is a path dependency (../emsutil) in EMerge's uv.lock,
              # so we redirect its source to the flake input and supply hatchling
              # (declared in emsutil's [build-system] but not auto-resolved for
              # path-sourced packages).
              (final: prev: {
                emsutil = prev.emsutil.overrideAttrs (old: {
                  src = inputs.emsutil-src;
                  nativeBuildInputs = (old.nativeBuildInputs or []) ++ final.resolveBuildSystem {
                    hatchling = [];
                  };
                });
              })

              # The Intel oneAPI wheel stack (mkl, tbb, umf, intel-cmplr-lib-ur,
              # tcmlib, intel-openmp, …) ships optional GPU/Level-Zero/OpenCL
              # adapters that all link against each other and against libhwloc,
              # libOpenCL, etc.  We don't carry any of those system libs, so we
              # tell autoPatchelf to ignore missing native deps across the board.
              # The CPU-only paths (BLAS, MKL, LAPACK) are unaffected.
              (_final: prev:
                lib.mapAttrs (_: pkg:
                  if pkg ? overrideAttrs
                  then pkg.overrideAttrs (_: { autoPatchelfIgnoreMissingDeps = true; })
                  else pkg
                ) prev
              )
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
            packages = [
              self'.packages.emerge-env
              pkgs.uv
            ];
            # gmsh (bundled in the emerge-env wheel) needs several OpenGL/X11 libs
            # at runtime that are not bundled in the wheel.
            # EMERGE_PARDISO_PATH points directly to the MKL library shipped in the
            # pip wheel, bypassing the filesystem-walk+cache that would otherwise
            # try to write to the read-only Nix store.
            shellHook = ''
              export LD_LIBRARY_PATH="${pkgs.libGLU}/lib:${pkgs.libGL}/lib:${pkgs.libxcursor}/lib:${pkgs.libxfixes}/lib:${pkgs.libxft}/lib:${pkgs.fontconfig.lib}/lib:${pkgs.libxinerama}/lib:$LD_LIBRARY_PATH"
              export EMERGE_PARDISO_PATH="${self'.packages.emerge-env}/lib/libmkl_rt.so.2"
            '';
          };
        };
    };
}
