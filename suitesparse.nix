{ stdenv, cmake, pkg-config, openblas, src }:

# SuiteSparse 7.x built from source: ships real pkg-config files and
# uses the single unified umfpack.h, which is what scikit-umfpack 0.4.2
# expects when it detects UMFPACK via pkg-config.
stdenv.mkDerivation {
  pname = "suitesparse";
  version = "7.12.2";
  inherit src;
  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ openblas ];
  cmakeFlags = [
    "-DSUITESPARSE_USE_CUDA=OFF"
    "-DSUITESPARSE_USE_OPENMP=OFF"
    "-DBUILD_TESTING=OFF"
    "-DSUITESPARSE_DEMOS=OFF"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    # Only build UMFPACK and its transitive dependencies;
    # SPEX/GraphBLAS/etc. pull in GMP/MPFR/OpenMP which we don't need.
    "-DSUITESPARSE_ENABLE_PROJECTS=suitesparse_config;amd;camd;colamd;ccolamd;cholmod;umfpack"
    # nixpkgs openblas is built with USE64BITINT (ILP64 ABI): it uses
    # 64-bit Fortran integers but keeps standard symbol names (dgemm_
    # etc., no _64 suffix).  cmake's BLA_SIZEOF_INTEGER=8 probe cannot
    # detect this variant, so SUITESPARSE_USE_64BIT_BLAS=ON alone does
    # not help.  Instead we pass -DBLAS64 directly; SuiteSparse_config.h
    # maps that to SUITESPARSE_BLAS_INT=int64_t with no name suffix,
    # which matches the nixpkgs openblas ILP64 convention exactly.
    "-DCMAKE_C_FLAGS=-DBLAS64"
    "-DCMAKE_CXX_FLAGS=-DBLAS64"
  ];
}
