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

      # First nixpkgs interpreter satisfying EMerge's requires-python; overridable via
      # emerge.python (e.g. when extra packages need a newer Python).
      defaultPython = lib.head (
        emerge-inputs.pyproject-nix.lib.util.filterPythonInterpreters {
          inherit (workspace) requires-python;
          inherit (pkgs) pythonInterpreters;
        }
      );

      python = cfg.python;

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
              # GCC 14+ promotes -Wint-conversion (and siblings) from warning to
              # a hard error by default.  The SWIG-generated _umfpack_wrap.c calls
              # the numpy import_array() macro from an int-returning function,
              # which trips -Wint-conversion.  Demote these back to warnings so the
              # legacy generated source still compiles.
              NIX_CFLAGS_COMPILE =
                (old.NIX_CFLAGS_COMPILE or "")
                + " -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration";
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

      # Runtime venv (run-emerge-simulation, run-emerge-headless) and the dev shell's venv:
      # the same package set, the dev one adds cfg.devDeps. Without devDeps they are the
      # same derivation.
      runtimeDeps = workspace.deps.default // { emerge = [ "umfpack" ]; } // cfg.extraDeps;
      emerge-env = pythonSet.mkVirtualEnv "emerge-env" runtimeDeps;
      emerge-dev-env =
        if cfg.devDeps == { } then
          emerge-env
        else
          pythonSet.mkVirtualEnv "emerge-dev-env" (runtimeDeps // cfg.devDeps);

      # Libraries every EMerge process needs, GUI or not: the gmsh wheel's libgmsh links
      # OpenGL/X11 (DT_NEEDED, mostly not on its rpath) even when only meshing, plus
      # SuiteSparse. run-emerge-headless gets only these; the viewer adds Qt (guiLibraryPath).
      headlessLibraryPath = lib.makeLibraryPath [
        pkgs.libGLU
        pkgs.libGL
        pkgs.libxcursor
        pkgs.libxfixes
        pkgs.libxft
        pkgs.fontconfig.lib
        pkgs.libxinerama
        cfg.suitesparse
      ];
      guiLibraryPath = lib.makeLibraryPath [
        pkgs.qt5.qtbase
        pkgs.libxkbcommon
      ];
      ldLibraryPath = "${headlessLibraryPath}:${guiLibraryPath}";
      qtPluginPath = "${pkgs.qt5.qtbase.bin}/lib/qt-${pkgs.qt5.qtbase.version}/plugins/platforms";
      pythonPath = "${python.pkgs.pyqt5}/${python.sitePackages}";
      # MKL's soname changes across releases (mkl 2025.x ships libmkl_rt.so.2,
      # 2026.x ships libmkl_rt.so.3), and consumers can swap the mkl version via
      # emerge.pythonOverlay.  Resolve whichever libmkl_rt.so.N the env actually
      # contains at build time (no IFD) and expose it at a stable path.  The
      # build fails if none is present, so a future layout change is caught at
      # build/`nix flake check` time rather than at the first linear solve.
      pardiso-lib = pkgs.runCommand "emerge-pardiso-lib" { } ''
        lib=${emerge-env}/lib
        target=$(ls "$lib"/libmkl_rt.so.* 2>/dev/null | sort -V | tail -n1 || true)
        if [ -z "$target" ]; then
          echo "error: no libmkl_rt.so.* found in $lib" >&2
          echo "       (is mkl missing from emerge-env, or has its layout changed?)" >&2
          exit 1
        fi
        # MKL's dispatcher loads libmkl_core, the threading layer etc. from the directory
        # it was loaded from (here $out/lib, not the target's), so every library of the
        # env goes next to it, not only libmkl_rt.
        mkdir -p $out/lib
        for f in "$lib"/*; do ln -s "$(readlink -f "$f")" "$out/lib/$(basename "$f")"; done
        ln -s "$(readlink -f "$target")" $out/lib/libmkl_rt.so
        # Load it the way EMerge does: a version query makes MKL load its core library.
        ${emerge-env}/bin/python -c '
        import ctypes, sys
        buf = ctypes.create_string_buffer(256)
        ctypes.CDLL(sys.argv[1]).MKL_Get_Version_String(buf, 256)
        print(buf.value.decode())
        ' $out/lib/libmkl_rt.so
      '';
      pardissoPath =
        if cfg.pardissoPath != null then cfg.pardissoPath else "${pardiso-lib}/lib/libmkl_rt.so";
    in
    {
      options.emerge = {
        suitesparse = lib.mkOption {
          type = lib.types.package;
          description = "SuiteSparse package to link scikit-umfpack against";
        };
        python = lib.mkOption {
          type = lib.types.package;
          default = defaultPython;
          defaultText = lib.literalMD "the first interpreter in `pkgs.pythonInterpreters` satisfying EMerge's `requires-python`";
          example = lib.literalExpression "pkgs.python312";
          description = ''
            Python interpreter used to build emerge-env. Must satisfy EMerge's
            requires-python (see its pyproject.toml).
          '';
        };
        pythonOverlay = lib.mkOption {
          # Not types.anything: that merges by applying the function and
          # deep-inspecting the resulting package set, which forces `final` and
          # recurses infinitely. Multiple definitions compose in order.
          type = lib.mkOptionType {
            name = "pythonOverlay";
            description = "pyproject-nix overlay (final: prev: { ... })";
            check = lib.isFunction;
            merge = _loc: defs: lib.composeManyExtensions (map (d: d.value) defs);
          };
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
        pardissoPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = lib.literalExpression ''"''${config.packages.emerge-env}/lib/libmkl_rt.so.3"'';
          description = ''
            Path exported as EMERGE_PARDISO_PATH. By default the highest
            libmkl_rt.so.N found in emerge-env is resolved automatically.
          '';
        };
        devDeps = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf lib.types.str);
          default = { };
          example = lib.literalExpression "{ pytest = [ ]; }";
          description = ''
            Python packages for the dev shell only (e.g. test tools): they go into
            emerge-dev-env, the shell's venv, which is emerge-env plus these, built from the
            same package set. emerge-env and the run-emerge-* runners don't get them. The
            shell exports EMERGE_ENV (the emerge-env store path) so tools can name the
            runtime environment their code was developed against.
          '';
        };
        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Extra nixpkgs packages to add to devShells.default";
        };
      };

      config = {
        # Default: pull suitesparse from emerge-flake's own build.
        # The main flake overrides this at regular priority with self'.packages.suitesparse,
        # so inputs'.emerge-flake is never evaluated there (Nix lazy evaluation).
        emerge.suitesparse = lib.mkDefault inputs'.emerge-flake.packages.suitesparse;

        # Fails if emerge-env contains no libmkl_rt.so.* (Pardiso would be broken).
        checks.pardiso-lib = pardiso-lib;

        packages = {
          emerge = pythonSet.emerge;
          emerge-env = emerge-env;
          emerge-dev-env = emerge-dev-env;

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

          # The same interpreter for batch jobs: no Qt/PyQt5 (the viewer), so a closure
          # without them, e.g. for cloud images. Same venv and core libraries as above.
          run-emerge-headless = pkgs.writeShellApplication {
            name = "run-emerge-headless";
            runtimeEnv = {
              LD_LIBRARY_PATH = headlessLibraryPath;
              EMERGE_PARDISO_PATH = pardissoPath;
            };
            text = ''
              exec ${emerge-env}/bin/python "$@"
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            emerge-dev-env
            pkgs.uv
            python.pkgs.pyqt5
          ]
          ++ cfg.extraPackages;
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
            export EMERGE_ENV="${emerge-env}"
          '';
        };
      };
    }
  );
}
