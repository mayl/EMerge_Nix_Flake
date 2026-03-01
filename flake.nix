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

          # SuiteSparse 7.x built from source: ships real pkg-config files and
          # uses the single unified umfpack.h, which is what scikit-umfpack 0.4.2
          # expects when it detects UMFPACK via pkg-config.
          suitesparse = pkgs.stdenv.mkDerivation {
            pname = "suitesparse";
            version = "7.12.2";
            src = inputs.suitesparse-src;
            nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
            buildInputs = [ pkgs.openblas ];
            cmakeFlags = [
              "-DSUITESPARSE_USE_CUDA=OFF"
              "-DSUITESPARSE_USE_OPENMP=OFF"
              "-DBUILD_TESTING=OFF"
              "-DSUITESPARSE_DEMOS=OFF"
              "-DCMAKE_INSTALL_LIBDIR=lib"
              # Only build UMFPACK and its transitive dependencies;
              # SPEX/GraphBLAS/etc. pull in GMP/MPFR/OpenMP which we don't need.
              "-DSUITESPARSE_ENABLE_PROJECTS=suitesparse_config;amd;camd;colamd;ccolamd;cholmod;umfpack"
            ];
          };

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

              # scikit-umfpack ships as an sdist only and must be compiled against
              # SuiteSparse (provides UMFPACK headers + libumfpack.so).
              # meson-python is the build backend but isn't declared in its manifest,
              # so we supply it (and meson/ninja/pkg-config/swig) explicitly.
              # SuiteSparse 7.x ships real pkg-config files, so dependency('UMFPACK')
              # succeeds and meson_swig.py can find umfpack_dep in
              # intro-dependencies.json.  It also uses the unified single umfpack.h,
              # which matches scikit-umfpack's single_header=true code path.
              (final: prev: {
                scikit-umfpack = prev.scikit-umfpack.overrideAttrs (old: {
                  nativeBuildInputs = (old.nativeBuildInputs or []) ++
                    final.resolveBuildSystem { "meson-python" = []; } ++
                    [ pkgs.meson pkgs.ninja pkgs.pkg-config pkgs.swig
                      final.numpy ];
                  buildInputs = (old.buildInputs or []) ++ [ suitesparse ];
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

            # Virtual environment for direct use, with the umfpack optional extra
            # so that scikit-umfpack is included alongside the default deps.
            emerge-env = pythonSet.mkVirtualEnv "emerge-env"
              (workspace.deps.default // { emerge = [ "umfpack" ]; });

            # Default output
            default = self'.packages.emerge;
          };

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
              export LD_LIBRARY_PATH="${lib.makeLibraryPath [
                pkgs.libGLU pkgs.libGL pkgs.libxcursor pkgs.libxfixes pkgs.libxft
                pkgs.fontconfig.lib pkgs.libxinerama pkgs.qt5.qtbase pkgs.libxkbcommon
                suitesparse
              ]}:$LD_LIBRARY_PATH"
              export QT_QPA_PLATFORM_PLUGIN_PATH="${pkgs.qt5.qtbase.bin}/lib/qt-${pkgs.qt5.qtbase.version}/plugins/platforms"
              export PYTHONPATH="${python.pkgs.pyqt5}/${python.sitePackages}:$PYTHONPATH"
              export EMERGE_PARDISO_PATH="${self'.packages.emerge-env}/lib/libmkl_rt.so.2"
            '';
          };
        };
    };
}
