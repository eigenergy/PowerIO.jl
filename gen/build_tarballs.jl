# BinaryBuilder recipe for a future PowerIO_jll. Current PowerIO.jl releases use
# eigenergy/powerio's release-binaries workflow plus gen/update_artifacts.jl, not
# this recipe. Before submitting a JLL, update the source revision and version to a
# release commit that exports every C ABI surface PowerIO.jl needs.
#
# Run:  julia build_tarballs.jl --verbose   (add a platform triplet to build one)
# Drop i686-w64-mingw32: the Rust toolchain target is troublesome and 32-bit Windows
# is not a target for this workload.

using BinaryBuilder

name = "PowerIO"
# Tracks the powerio-capi *crate* version (the binary). The PowerIO.jl package
# version moves independently; the ABI checks decide whether a binary is
# usable, not the version number.
version = v"0.5.0"

# Historical revision for the JLL prototype. The release artifact pipeline does not
# use it.
sources = [
    GitSource("https://github.com/eigenergy/powerio.git",
              "b9d57b0a32ad9628e36ec7ba30aa5d60167e6089"),
]

# `cargo build` writes the cdylib under target/<rust_target>/release. Names differ
# per platform: lib*.so (linux), lib*.dylib (macos), *.dll (+ *.dll.a import lib)
# (windows, no lib prefix, ships under bin/). `install_license` keeps AutoMerge happy.
script = raw"""
cd $WORKSPACE/srcdir/powerio
# --features arrow ships pio_to_arrow; --features matrix ships the matrix COO
# Arrow tables when the selected source supports them; --features gridfm ships
# pio_read_dir / pio_scenario_ids; --features dist ships pio_dist_*;
# --features pkg ships pio_package_*; --features prob ships pio_scopf_*.
features=arrow,gridfm,dist
if grep -q '^matrix = ' powerio-capi/Cargo.toml; then
    features="${features},matrix"
fi
if grep -q '^pkg = ' powerio-capi/Cargo.toml; then
    features="${features},pkg"
fi
if grep -q '^prob = ' powerio-capi/Cargo.toml; then
    features="${features},prob"
fi
cargo build --release -p powerio-capi --target ${rust_target} --features "${features}"
out=target/${rust_target}/release
if [[ "${target}" == *-mingw32* ]]; then
    install -Dvm755 "${out}/powerio_capi.dll" "${bindir}/libpowerio_capi.dll"
else
    install -Dvm755 "${out}/libpowerio_capi.${dlext}" "${libdir}/libpowerio_capi.${dlext}"
fi
install -Dvm644 powerio-capi/include/powerio.h "${includedir}/powerio.h"
# powerio declares "MIT OR Apache-2.0"; LICENSE-MIT and LICENSE-APACHE ship at
# the repo root.
install_license LICENSE*
"""

platforms = [
    Platform("x86_64", "linux"; libc="glibc"),
    Platform("aarch64", "linux"; libc="glibc"),
    Platform("x86_64", "macos"),
    Platform("aarch64", "macos"),
    Platform("x86_64", "windows"),
]

products = [
    LibraryProduct("libpowerio_capi", :libpowerio_capi),
]

dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
    compilers=[:c, :rust], julia_compat="1.9")  # matches Project.toml's julia floor
