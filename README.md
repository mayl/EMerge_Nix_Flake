# EMerge Nix Flake

Nix flake packaging the [EMerge](https://github.com/FennisRobert/EMerge) Python EM simulation
library. Pardiso and SuperLU work out of the box; UMFPACK requires the custom SuiteSparse build
this flake provides.

## Quick start — project template

```bash
nix flake init -t github:mayl/EMerge_Nix_Flake
nix run          # runs simulation.py
nix develop      # enter devshell with EMerge on $PATH
```

The template includes a working `simulation.py` (parallel-plate waveguide demo) and a
`flake.nix` wired up to this flake's module.

## What you get

After importing the module, every system in `perSystem` exposes:

| Output | Description |
|--------|-------------|
| `packages.emerge` | The EMerge Python package (wheel) |
| `packages.emerge-env` | Virtualenv with EMerge + all deps + UMFPACK extra |
| `packages.run-emerge-simulation` | Shell wrapper — runs a `.py` file inside the venv with all required env vars set |
| `devShells.default` | Shell with the venv, uv, PyQt5, and correct `LD_LIBRARY_PATH` / Qt / MKL env vars |

## Using the module in your own flake

Add the flake as an input, import its module, then configure in `perSystem`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    emerge-flake = {
      url = "github:mayl/EMerge_Nix_Flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.emerge-flake.flakeModules.default ];

      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { self', pkgs, lib, ... }: {
        # Wire a default package to the simulation runner:
        packages.default = pkgs.writeShellScriptBin "run-simulation" ''
          exec ${lib.getExe self'.packages.run-emerge-simulation} ${./simulation.py} "$@"
        '';
      };
    };
}
```

## Running simulations

`packages.run-emerge-simulation` is a wrapper around the venv's Python interpreter with all
runtime environment variables pre-set (OpenGL, Qt, MKL). Pass your script as the first
argument:

```bash
# nix run style
nix run .#run-emerge-simulation -- my_sim.py

# or wire it as packages.default so that nix run works:
nix run -- my_sim.py
```

## Configuration options

All options live under `emerge.*` in `perSystem`.

### `emerge.extraDeps` — include more Python packages in the venv

EMerge's lockfile contains many packages that are not pulled into the venv by default. Use
`extraDeps` to include them:

```nix
perSystem = { ... }: {
  emerge.extraDeps = {
    "matplotlib" = [ ];          # no extras needed
    "scipy" = [ ];
    "some-package" = [ "extra" ]; # with an optional extra
  };
};
```

The keys must be package names that already appear in EMerge's `uv.lock`. This option only
selects packages from the existing locked set — it does not pull in packages from outside the
lockfile. To add entirely new packages, use `pythonOverlay` instead.

### `emerge.pythonOverlay` — add new Python packages to the set

Use a [pyproject-nix](https://pyproject-nix.github.io/pyproject.nix/) overlay to inject
packages that are not in EMerge's lockfile at all. The overlay follows the standard
`final: prev: { ... }` pattern:

```nix
perSystem = { pkgs, ... }: {
  emerge.pythonOverlay = final: prev: {
    # A package defined in your repo:
    my-analysis-lib = final.callPackage ./my-analysis-lib.nix { };

    # A nixpkgs Python package not in the lockfile:
    h5py = prev.h5py.overrideAttrs (old: {
      buildInputs = (old.buildInputs or []) ++ [ pkgs.hdf5 ];
    });
  };
};
```

After adding a package via `pythonOverlay`, make it available in the venv by also listing it in
`emerge.extraDeps`:

```nix
emerge.extraDeps = {
  "my-analysis-lib" = [ ];
  "h5py" = [ ];
};
```

### `emerge.extraPackages` — add programs to the devshell

Adds arbitrary nixpkgs packages to `devShells.default`. This is for programs (CLI tools,
compilers, etc.), not Python libraries.

```nix
perSystem = { pkgs, ... }: {
  emerge.extraPackages = [ pkgs.ripgrep pkgs.gnuplot ];
};
```

### `emerge.suitesparse` — custom SuiteSparse build (advanced)

By default the module uses the SuiteSparse build from this flake. Override this only if you need
a different version or build configuration:

```nix
perSystem = { pkgs, ... }: {
  emerge.suitesparse = pkgs.callPackage ./my-suitesparse.nix { };
};
```

## Supported platforms

`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`. Linux is the primary
target; macOS builds are untested.
