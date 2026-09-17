# Binary distribution

PowerIO.jl wraps the Rust `powerio-capi` library. On a supported platform it
arrives as a prebuilt binary, so you do not compile anything.

## Pipeline

1. A version tag on [eigenergy/powerio](https://github.com/eigenergy/powerio)
   triggers its `release-binaries` workflow, which builds
   `libpowerio_capi.<triplet>.tar.gz` with the `arrow`, `matrix`, `gridfm`,
   `dist`, and `prob` features for Linux glibc (`x86_64`, `aarch64`),
   macOS (`x86_64`, `arm64`), and Windows (`x86_64`), and attaches the five
   tarballs to the GitHub release. Each tarball holds the library under `lib/`
   (`bin/` on Windows), the C header under `include/`, and the licenses.
2. A reviewed `.github/powerio-release.toml` names the exact tag and binds it to
   the final Julia source digest. "Update artifacts" downloads the five
   tarballs, computes each one's SHA-256 and unpacked git tree hash, and asks
   `gen/update_artifacts.jl` to build `Artifacts.toml`. Before writing, the
   generator loads the host library and checks its ABI number (7), its version
   string against the tag, the core entry points the binding calls, and that
   it parses the GridFM fixture. If any of those checks fail, the update is
   parked and `Artifacts.toml` is left untouched. The workflow tests the exact
   result, commits only `Artifacts.toml`, pushes only when `main` has not
   moved, and dispatches registration for that exact SHA. See CONTRIBUTING.md
   for the state machine and recovery commands.
3. `Artifacts.toml` is lazy, so `Pkg.add` downloads nothing; the tarball for
   your platform is fetched on the first call that needs the library.

A `PowerIO_jll` built from `gen/build_tarballs.jl` (the BinaryBuilder recipe)
is the planned long term distribution; current releases use the artifact
pipeline above.

## Generated declarations

The C header in each tarball is also the input to the binding's raw layer.
`src/LibPowerIO.jl` is generated from `powerio-capi/include/powerio.h` by
`gen/generate.jl`, a Clang.jl generator project under `gen/`, and declares
every entry point, view struct, and opaque handle type, along with the ABI
number the binding targets. It is never edited by hand:

```
julia --project=gen -e 'using Pkg; Pkg.instantiate()'
julia --project=gen gen/generate.jl ../powerio/powerio-capi/include/powerio.h
```

The generator is deterministic, so an unchanged header reproduces the file
byte for byte and a stale checkout shows up as a diff in CI.

## Resolution order

The library resolves in this order:

1. `set_library!(path)` or the `POWERIO_CAPI` environment variable,
2. the saved Preferences.jl `library` override,
3. a sibling `powerio` checkout's `target/{release,debug}` build, only when
   this package is itself a git checkout,
4. the `powerio_capi` artifact,
5. a plain `libpowerio_capi` on the loader path.

On an unsupported platform the artifact lookup fails, and the other entries
let you keep working from a local build.

```julia
using PowerIO

set_library!("/path/to/libpowerio_capi.dylib"; persist=true)
clear_library!(persist=true)
```

```@docs
set_library!
clear_library!
abi_version
library_version
library_available
```

## Paired release preparation

The [paired release procedure](https://github.com/eigenergy/powerio/blob/main/docs/src/paired-releases.md)
records exact source commits and tested binaries in a published manifest.
It does not require manually editing a release intent or refreshing a source
checksum. The legacy intent helper applies only before paired automation is
activated. Registration uses the approved candidate commit, even if `main`
has advanced; a separate PR synchronizes its artifact references afterward.
