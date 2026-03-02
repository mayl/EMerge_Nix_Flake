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
    suitesparse-src = {
      url = "github:DrTimothyAldenDavis/SuiteSparse/v7.12.2";
      flake = false;
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

      flake = {
        templates.default = {
          path = ./template;
          description = "EMerge EM simulation starter";
        };
      };

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          lib,
          system,
          ...
        }:
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
              (final: prev: {
                # emsutil: path dependency in EMerge's uv.lock; redirect source to
                # the flake input and supply hatchling (declared in emsutil's
                # [build-system] but not auto-resolved for path-sourced packages).
                emsutil = prev.emsutil.overrideAttrs (old: {
                  src = inputs.emsutil-src;
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ])
                    ++ final.resolveBuildSystem {
                      hatchling = [ ];
                    };
                });
                # scikit-umfpack: sdist-only; compiled against our SuiteSparse build
                # (UMFPACK headers + libumfpack.so).  meson-python is the build
                # backend but isn't declared in its manifest, so we supply it along
                # with meson/ninja/pkg-config/swig explicitly.
                scikit-umfpack = prev.scikit-umfpack.overrideAttrs (old: {
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ])
                    ++ final.resolveBuildSystem { "meson-python" = [ ]; }
                    ++ [
                      pkgs.meson
                      pkgs.ninja
                      pkgs.pkg-config
                      pkgs.swig
                      final.numpy
                    ];
                  buildInputs = (old.buildInputs or [ ]) ++ [ self'.packages.suitesparse ];
                });
              })

              # The Intel oneAPI wheel stack (mkl, tbb, umf, intel-cmplr-lib-ur,
              # tcmlib, intel-openmp, …) ships optional GPU/Level-Zero/OpenCL
              # adapters that all link against each other and against libhwloc,
              # libOpenCL, etc.  We don't carry any of those system libs, so we
              # tell autoPatchelf to ignore missing native deps across the board.
              # The CPU-only paths (BLAS, MKL, LAPACK) are unaffected.
              (
                _final: prev:
                lib.mapAttrs (
                  _: pkg:
                  if pkg ? overrideAttrs then
                    pkg.overrideAttrs (_: {
                      autoPatchelfIgnoreMissingDeps = true;
                    })
                  else
                    pkg
                ) prev
              )
            ]
          );
        in
        {
          packages = {
            suitesparse = pkgs.callPackage ./suitesparse.nix {
              src = inputs.suitesparse-src;
            };

            # The emerge package
            emerge = pythonSet.emerge;

            # Virtual environment for direct use, with the umfpack optional extra
            # so that scikit-umfpack is included alongside the default deps.
            emerge-env = pythonSet.mkVirtualEnv "emerge-env" (
              workspace.deps.default // { emerge = [ "umfpack" ]; }
            );

            # Python interpreter wrapped with all runtime env vars needed to run
            # EMerge simulations (library paths, Qt, PyQt5, MKL).
            # Pass a simulation script as the first argument: nix run .#run-emerge-simulation -- sim.py
            run-emerge-simulation = pkgs.writeShellApplication {
              name = "run-emerge-simulation";
              runtimeEnv = {
                LD_LIBRARY_PATH = lib.makeLibraryPath [
                  pkgs.libGLU
                  pkgs.libGL
                  pkgs.libxcursor
                  pkgs.libxfixes
                  pkgs.libxft
                  pkgs.fontconfig.lib
                  pkgs.libxinerama
                  pkgs.qt5.qtbase
                  pkgs.libxkbcommon
                  self'.packages.suitesparse
                ];
                QT_QPA_PLATFORM_PLUGIN_PATH = "${pkgs.qt5.qtbase.bin}/lib/qt-${pkgs.qt5.qtbase.version}/plugins/platforms";
                PYTHONPATH = "${python.pkgs.pyqt5}/${python.sitePackages}";
                EMERGE_PARDISO_PATH = "${self'.packages.emerge-env}/lib/libmkl_rt.so.2";
              };
              text = ''
                exec ${self'.packages.emerge-env}/bin/python "$@"
              '';
            };

            # Default output
            default = self'.packages.emerge;
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = pkgs.mkShell {
            packages = [
              self'.packages.emerge-env
              pkgs.uv
              python.pkgs.pyqt5
            ];
            # gmsh (bundled in the emerge-env wheel) needs several OpenGL/X11 libs
            # at runtime that are not bundled in the wheel.
            # EMERGE_PARDISO_PATH points directly to the MKL library shipped in the
            # pip wheel, bypassing the filesystem-walk+cache that would otherwise
            # try to write to the read-only Nix store.
            shellHook = ''
              export LD_LIBRARY_PATH="${
                lib.makeLibraryPath [
                  pkgs.libGLU
                  pkgs.libGL
                  pkgs.libxcursor
                  pkgs.libxfixes
                  pkgs.libxft
                  pkgs.fontconfig.lib
                  pkgs.libxinerama
                  pkgs.qt5.qtbase
                  pkgs.libxkbcommon
                  self'.packages.suitesparse
                ]
              }:$LD_LIBRARY_PATH"
              export QT_QPA_PLATFORM_PLUGIN_PATH="${pkgs.qt5.qtbase.bin}/lib/qt-${pkgs.qt5.qtbase.version}/plugins/platforms"
              export PYTHONPATH="${python.pkgs.pyqt5}/${python.sitePackages}:$PYTHONPATH"
              export EMERGE_PARDISO_PATH="${self'.packages.emerge-env}/lib/libmkl_rt.so.2"
            '';
          };
        };
    };
}
