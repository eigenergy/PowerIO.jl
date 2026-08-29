# Binary distribution

PowerIO.jl wraps the Rust `powerio-capi` cdylib, shipped as a prebuilt binary
for each platform; users never compile it.

## Pipeline

1. A version tag on [eigenergy/powerio](https://github.com/eigenergy/powerio)
   triggers its `release-binaries` workflow, which builds
   `libpowerio_capi.<triplet>.tar.gz` with the `arrow`, `matrix`, `gridfm`,
   `dist`, and `prob` features for Linux glibc (`x86_64`, `aarch64`),
   macOS (`x86_64`, `arm64`), and Windows (`x86_64`), and attaches the five
   tarballs to the GitHub release. Each tarball holds the cdylib under `lib/`
   (`bin/` on Windows), the C header under `include/`, and the licenses.
2. A reviewed `.github/powerio-release.toml` names the exact tag and binds it to
   the final Julia source digest. "Update artifacts" downloads the five
   tarballs, computes each one's SHA-256 and unpacked git-tree-sha1, and asks
   `gen/update_artifacts.jl` to build `Artifacts.toml`. Before writing, the
   generator verifies the core and distribution ABIs, all six features and
   representative symbols, and both `pio_schema_versions_json` and
   `pio_build_info`. A semantic mismatch parks with `Artifacts.toml` untouched.
   The workflow tests the exact result, commits only `Artifacts.toml`, pushes
   only when `main` has not moved, and dispatches registration for that exact
   SHA. See CONTRIBUTING.md for the state machine and recovery commands.
3. `Artifacts.toml` is lazy: nothing downloads at `Pkg.add`; the tarball for the
   current platform is fetched on the first call that needs the library.

## Resolution order

`_lib()` resolves the library in this order:

1. `set_library!(path)` / the `POWERIO_CAPI` environment variable
   (the dev override),
2. the saved Preferences.jl `library` override,
3. a sibling `powerio` checkout's `target/{release,debug}` build,
4. the `powerio_capi` artifact,
5. a plain `libpowerio_capi` on the loader path.

On an unsupported platform the artifact lookup fails and the fallbacks keep a
local build working.

```julia
using PowerIO

set_library!("/path/to/libpowerio_capi.dylib"; persist=true)
clear_library!(persist=true)
```

## JLL

A `PowerIO_jll` built from `gen/build_tarballs.jl` (the BinaryBuilder recipe)
is the planned long-term distribution; current releases use the artifact
pipeline above.
