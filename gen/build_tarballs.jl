# BinaryBuilder recipe for the powerio-capi C ABI (libpowerio_capi).
#
# Two uses, one recipe:
#   1. Self-hosted distribution (issue #8, now): cross-compile the per-platform
#      tarballs, upload them to a PowerIO.jl GitHub release, and reference them from
#      the package's Artifacts.toml. The build prints each tarball's sha256 and the
#      artifact's git-tree-sha1; paste those into Artifacts.toml.
#   2. Yggdrasil PowerIO_jll (issue #1, later): submit this file to Yggdrasil
#      essentially unchanged; PowerIO's `_lib()` then swaps to PowerIO_jll.
#
# Run:  julia build_tarballs.jl --verbose   (add a platform triplet to build one)
# Drop i686-w64-mingw32: the Rust toolchain target is troublesome and 32-bit Windows
# is not a target for this workload.

using BinaryBuilder

name = "PowerIO"
# Tracks the powerio-capi *crate* version (the binary). The PowerIO.jl package
# version moves independently (0.2.0 here); the ABI checks decide whether a
# binary is usable, not the version number.
version = v"0.3.1"

# Must pin a commit reporting `PIO_ABI_VERSION` 4: the binding's load-time
# handshake refuses anything else, and `to_arrow` / the dist surface need their
# features. Pinned to the v0.3.1 release commit, which also reports
# `PIO_DIST_ABI_VERSION` 1 for the distribution C ABI.
sources = [
    GitSource("https://github.com/eigenergy/powerio.git",
              "fc3394ac21d7b236eb3b7557c3629aaecd9b8235"),
]

# `cargo build` writes the cdylib under target/<rust_target>/release. Names differ
# per platform: lib*.so (linux), lib*.dylib (macos), *.dll (+ *.dll.a import lib)
# (windows, no lib prefix, ships under bin/). `install_license` keeps AutoMerge happy.
script = raw"""
cd $WORKSPACE/srcdir/powerio
# --features arrow ships pio_to_arrow (the zero-copy Arrow C Data Interface export
# to_arrow calls); --features gridfm ships pio_read_dir / pio_scenario_ids (the
# gridfm-datakit Parquet reader read_gridfm calls); --features dist ships the
# pio_dist_* surface (the OpenDSS / PMD / BMOPF distribution binding). The base
# ABI is identical without them. This matches powerio's release-binaries.yml.
cargo build --release -p powerio-capi --target ${rust_target} --features arrow,gridfm,dist
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
