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
# Tracks the powerio-capi *crate* version (the binary), which is independent of the
# PowerIO.jl *package* version (0.0.1). The crate is at 0.1.0 as of the pinned commit.
version = v"0.1.0"

# Pinned to the merged #45 commit ("Rename to PowerIO ... v0.1.0 hardening"), which
# carries the rename and the pio_to_json keystone. Prefer a git tag once one is cut
# (none exists yet); a tag is the right long-term anchor for a reproducible build.
sources = [
    GitSource("https://github.com/eigenergy/powerio.git",
              "5d7e76bdb0b870cac0c12846bdc7b5b3d952cdec"),
]

# `cargo build` writes the cdylib under target/<rust_target>/release. Names differ
# per platform: lib*.so (linux), lib*.dylib (macos), *.dll (+ *.dll.a import lib)
# (windows, no lib prefix, ships under bin/). `install_license` keeps AutoMerge happy.
script = raw"""
cd $WORKSPACE/srcdir/powerio
cargo build --release -p powerio-capi --target ${rust_target}
out=target/${rust_target}/release
if [[ "${target}" == *-mingw32* ]]; then
    install -Dvm755 "${out}/powerio_capi.dll" "${bindir}/libpowerio_capi.dll"
else
    install -Dvm755 "${out}/libpowerio_capi.${dlext}" "${libdir}/libpowerio_capi.${dlext}"
fi
install -Dvm644 powerio-capi/include/powerio.h "${includedir}/powerio.h"
# powerio declares "MIT OR Apache-2.0" (powerio-capi/Cargo.toml) but ships no LICENSE
# file at the pinned commit, so don't abort on a missing one. A LICENSE must land
# upstream before the Yggdrasil submission, where AutoMerge requires it; the
# self-hosted GitHub-release path does not.
install_license LICENSE* || true
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
