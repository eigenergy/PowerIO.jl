# Binary distribution

PowerIO.jl wraps the Rust `powerio-capi` cdylib. Users never compile it:
`deps/build.jl` running `cargo` on every machine is the deprecated path, and
PowerIO does not use it.

## Pipeline

1. A version tag on [eigenergy/powerio](https://github.com/eigenergy/powerio)
   triggers its `release-binaries` workflow, which builds
   `libpowerio_capi.<triplet>.tar.gz` with the `arrow` feature for Linux glibc
   (x86_64, aarch64), macOS (x86_64, arm64), and Windows (x86_64), and
   attaches the five tarballs to the GitHub release. Each tarball
   holds the cdylib under `lib/` (`bin/` on Windows), the C header under
   `include/`, and the licenses.
2. In this repository, `julia gen/update_artifacts.jl <tag>` downloads the five
   tarballs, computes each one's sha256 and unpacked git-tree-sha1, and rewrites
   `Artifacts.toml`. Commit the result.
3. `Artifacts.toml` is lazy: nothing downloads at `Pkg.add`; the tarball for the
   current platform is fetched on the first call that needs the library.

## Resolution order

`_lib()` resolves the library in this order:

1. `PowerIO.set_library!(path)` / the `POWERIO_CAPI` environment variable
   (the dev override),
2. the `powerio_capi` artifact,
3. a sibling `powerio` checkout's `target/{release,debug}` build,
4. a plain `libpowerio_capi` on the loader path.

On an unsupported platform the artifact lookup fails and the fallbacks keep a
local build working.

## Yggdrasil

A `PowerIO_jll` built from `gen/build_tarballs.jl` (the BinaryBuilder recipe) is
the eventual canonical form, a one-line `_lib()` swap, but it does not gate
the release.
