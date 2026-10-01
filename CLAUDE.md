# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Nix flake packaging the [EMerge](https://github.com/FennisRobert/EMerge) Python EM simulation library. Supported solvers: UMFPACK (custom-built SuiteSparse derivation) and Pardiso (Intel MKL from the Intel oneAPI wheel stack bundled in the venv; `EMERGE_PARDISO_PATH` is pre-set to the env's `libmkl_rt.so.N`, resolved at build time).

## Common Commands

```bash
nix develop          # Enter devshell (builds emerge-env on first run)
nix build .#emerge        # Build the emerge Python package
nix build .#emerge-env    # Build the virtual environment with umfpack extra
nix build .#suitesparse   # Build SuiteSparse from source
nix fmt              # Format Nix files (nixfmt-tree)
nix flake update     # Update all flake inputs
```

Run a demo after entering the devshell:
```bash
python EMerge_2_0_Example_Pack/examples/demo0_parallel_plate.py  # ~1 min due to numba JIT
```

## Architecture

Two source files define everything:

- **`flake.nix`** — builds the Python package set using `uv2nix` against EMerge's `uv.lock`, applies overlays for `scikit-umfpack` (compiled against our SuiteSparse) and the Intel oneAPI wheel stack (GPU adapters don't need patching). The `emerge-env` output is a virtualenv with the `umfpack` optional extra included.
- **`suitesparse.nix`** — builds SuiteSparse 7.12.2 from source using CMake, enabling only the UMFPACK subset (suitesparse_config, amd, camd, colamd, ccolamd, cholmod, umfpack).

## Critical: nixpkgs openblas ILP64 Hack

`pkgs.openblas` on nixos-unstable uses ILP64 (64-bit Fortran integers) but keeps standard symbol names (`dgemm_`, not `dgemm_64`). CMake's `BLA_SIZEOF_INTEGER=8` probe cannot detect this, so SuiteSparse must be told explicitly:

```nix
"-DCMAKE_C_FLAGS=-DBLAS64"
"-DCMAKE_CXX_FLAGS=-DBLAS64"
```

This maps `SUITESPARSE_BLAS_INT` to `int64_t` without the `_64` suffix, matching the nixpkgs convention. **Do not** use `-DSUITESPARSE_USE_64BIT_BLAS=ON` — it silently falls back to int32_t and segfaults at runtime.

## devShell Details

The shell hook sets:
- `LD_LIBRARY_PATH` — OpenGL/X11 libs gmsh links (even headless) and the SuiteSparse `lib/` dir (`headlessLibraryPath`), plus Qt for the viewer (`guiLibraryPath`)
- `QT_QPA_PLATFORM_PLUGIN_PATH` — Qt5 platform plugins for gmsh's GUI
- `PYTHONPATH` — adds PyQt5 (provided from nixpkgs, not the venv)
- `EMERGE_PARDISO_PATH` — `emerge-pardiso-lib/lib/libmkl_rt.so`: a stable name for the env's `libmkl_rt.so.N`, next to links to every library of the env (MKL loads `libmkl_core` etc. from its own directory); bypasses the filesystem-walk cache that would try to write to the read-only Nix store
- `EMERGE_ENV` — the `emerge-env` store path (the shell's own venv is `emerge-dev-env` = `emerge-env` + `emerge.devDeps`)

`run-emerge-headless` sets only the headless `LD_LIBRARY_PATH` and `EMERGE_PARDISO_PATH`.
