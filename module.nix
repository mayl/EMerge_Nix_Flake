{
  flake-parts-lib,
  inputs,
  ...
}:
let
  # Resolve EMerge's sub-inputs regardless of whether we're the main flake
  # (emerge-flake absent → emerge-inputs = inputs) or a consumer
  # (emerge-flake present → emerge-inputs = inputs.emerge-flake.inputs).
  emerge-inputs = (inputs.emerge-flake or inputs).inputs or inputs;
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    {
      config,
      inputs',
      pkgs,
      lib,
      ...
    }:
    let
      cfg = config.emerge;

      workspace = emerge-inputs.uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = emerge-inputs.emerge-src;
      };

      python = lib.head (
        emerge-inputs.pyproject-nix.lib.util.filterPythonInterpreters {
          inherit (workspace) requires-python;
          inherit (pkgs) pythonInterpreters;
        }
      );

      pythonBase = pkgs.callPackage emerge-inputs.pyproject-nix.build.packages {
        inherit python;
      };

      workspaceOverlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      basePythonSet = pythonBase.overrideScope (
        lib.composeManyExtensions [
          emerge-inputs.pyproject-build-systems.overlays.default
          workspaceOverlay
          (final: prev: {
            # emsutil: path dependency in EMerge's uv.lock; redirect source to
            # the flake input and supply hatchling (declared in emsutil's
            # [build-system] but not auto-resolved for path-sourced packages).
            emsutil = prev.emsutil.overrideAttrs (old: {
              src = emerge-inputs.emsutil-src;
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
              buildInputs = (old.buildInputs or [ ]) ++ [ cfg.suitesparse ];
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

      pythonSet = basePythonSet.overrideScope cfg.pythonOverlay;

      emerge-env = pythonSet.mkVirtualEnv "emerge-env" (
        workspace.deps.default // { emerge = [ "umfpack" ]; } // cfg.extraDeps
      );

      # Shared runtime environment — used by both run-emerge-simulation and devShells.default
      ldLibraryPath = lib.makeLibraryPath [
        pkgs.libGLU
        pkgs.libGL
        pkgs.libxcursor
        pkgs.libxfixes
        pkgs.libxft
        pkgs.fontconfig.lib
        pkgs.libxinerama
        pkgs.qt5.qtbase
        pkgs.libxkbcommon
        cfg.suitesparse
      ];
      qtPluginPath = "${pkgs.qt5.qtbase.bin}/lib/qt-${pkgs.qt5.qtbase.version}/plugins/platforms";
      pythonPath = "${python.pkgs.pyqt5}/${python.sitePackages}";
      pardissoPath = "${emerge-env}/lib/libmkl_rt.so.2";
    in
    {
      options.emerge = {
        suitesparse = lib.mkOption {
          type = lib.types.package;
          description = "SuiteSparse package to link scikit-umfpack against";
        };
        pythonOverlay = lib.mkOption {
          type = lib.types.anything;
          default = _: _: { };
          description = "pyproject-nix overlay to extend the Python package set";
        };
        extraDeps = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf lib.types.str);
          default = { };
          description = ''
            Extra packages to include in emerge-env: { "package-name" = [ extras ]; }
          '';
        };
      };

      config = {
        # Default: pull suitesparse from emerge-flake's own build.
        # The main flake overrides this at regular priority with self'.packages.suitesparse,
        # so inputs'.emerge-flake is never evaluated there (Nix lazy evaluation).
        emerge.suitesparse = lib.mkDefault inputs'.emerge-flake.packages.suitesparse;

        packages = {
          emerge = pythonSet.emerge;
          emerge-env = emerge-env;

          # Python interpreter wrapped with all runtime env vars needed to run
          # EMerge simulations (library paths, Qt, PyQt5, MKL).
          # Pass a simulation script as the first argument: nix run .#run-emerge-simulation -- sim.py
          run-emerge-simulation = pkgs.writeShellApplication {
            name = "run-emerge-simulation";
            runtimeEnv = {
              LD_LIBRARY_PATH = ldLibraryPath;
              QT_QPA_PLATFORM_PLUGIN_PATH = qtPluginPath;
              PYTHONPATH = pythonPath;
              EMERGE_PARDISO_PATH = pardissoPath;
            };
            text = ''
              exec ${emerge-env}/bin/python "$@"
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            emerge-env
            pkgs.uv
            python.pkgs.pyqt5
          ];
          # gmsh (bundled in the emerge-env wheel) needs several OpenGL/X11 libs
          # at runtime that are not bundled in the wheel.
          # EMERGE_PARDISO_PATH points directly to the MKL library shipped in the
          # pip wheel, bypassing the filesystem-walk+cache that would otherwise
          # try to write to the read-only Nix store.
          shellHook = ''
            export LD_LIBRARY_PATH="${ldLibraryPath}:$LD_LIBRARY_PATH"
            export QT_QPA_PLATFORM_PLUGIN_PATH="${qtPluginPath}"
            export PYTHONPATH="${pythonPath}:$PYTHONPATH"
            export EMERGE_PARDISO_PATH="${pardissoPath}"
          '';
        };
      };
    }
  );
}
