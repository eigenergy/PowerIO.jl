# Binary distribution

PowerIO.jl wraps the Rust `powerio-capi` library. On a supported platform it
arrives as a prebuilt binary, so you do not compile anything.

## Pipeline

1. A version tag on [eigenergy/powerio](https://github.com/eigenergy/powerio)
   triggers its `release-binaries` workflow, which builds
   `libpowerio_capi.<triplet>.tar.gz` with the `matrix`, `gridfm`, `dist`,
   and `prob` features for Linux glibc (`x86_64`, `aarch64`),
   macOS (`x86_64`, `arm64`), and Windows (`x86_64`), and attaches the five
   tarballs to the GitHub release. Each tarball holds the library under `lib/`
   (`bin/` on Windows), the C header under `include/`, and the licenses.
2. Publishing a stable release starts the PowerIO.jl "Release" workflow, which
   downloads the five tarballs, computes each one's SHA-256 and unpacked git
   tree hash, and asks `gen/update_artifacts.jl` to build `Artifacts.toml`.
   Before writing, the generator loads the host library and checks that its
   release, read through `pio_version_numbers`, is in the release series of
   the binding's header and no older than that header; its version string
   against the tag; the core entry points the binding calls; and that it
   parses the GridFM fixture. A failed check stops the release and leaves
   `Artifacts.toml` untouched. The workflow then runs the full test suite
   against the pinned binaries, pushes the release commit that sets the
   matching PowerIO.jl version, and registers it. See CONTRIBUTING.md.
3. `Artifacts.toml` is lazy, so `Pkg.add` downloads nothing; the tarball for
   your platform is fetched on the first call that needs the library.

## Generated declarations

The C header in each tarball is also the input to the binding's raw layer.
`src/LibPowerIO.jl` is generated from `powerio-capi/include/powerio.h` by
`gen/generate.jl`, a Clang.jl generator project under `gen/`, and declares
every entry point, view struct, and opaque handle type, along with the
release the header was generated from (`PIO_VERSION_MAJOR`,
`PIO_VERSION_MINOR`, `PIO_VERSION_PATCH`). It is never edited by hand:

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

# Check a candidate build before changing the active library.
library_available("/path/to/candidate/libpowerio_capi.dylib")

set_library!("/path/to/libpowerio_capi.dylib"; persist=true)
clear_library!(persist=true)
```

```@docs
set_library!
clear_library!
library_version
library_available
```

## Why the binding uses C and a separate Julia package

Julia's [native C interface](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/)
provides direct ABI calls without a Julia-specific Rust runtime. The generated
raw declarations, owner-rooted handles, copied borrowed views, `GC.@preserve`,
and entry-point coverage checks form the safety boundary. Typed values and
`TimeSeries` remain Julia interfaces over those handles; serialization is an
exchange operation, not the implementation of property access.

[jlrs](https://docs.rs/jlrs/latest/jlrs/) supports embedding Julia and exposing
Rust types/functions through Julia modules. That is valuable when a Rust program
needs Julia execution, but PowerIO's data library does not require it. Adding
libJulia/JlrsCore coupling would add another compatibility surface to every
release. The public [miguelraz/RustCall.jl](https://github.com/miguelraz/RustCall.jl) repository inspected in November 2026
contains a minimal `hello_world` module, not a replacement for this binding's
ownership, generation and distribution machinery.

[BinaryBuilder and Yggdrasil](https://docs.binarybuilder.org/stable/) address
cross-compilation and JLL packaging; they are complementary to the C interface.
A future `PowerIO_jll` could replace the artifact source while keeping the typed
API. First demonstrate all supported platforms, native dependencies, version
checks, symbols, licenses and tests with reproducible recipes. The existing
five-platform release gate already tests the exact artifacts the Julia package
pins. Do not replace it merely to change packaging tools.

Keeping PowerIO.jl as its registered Julia repository preserves Documenter,
General registration and Julia-focused contributor workflows. Matching companion
branches and artifact tests provide integration across repositories. A monorepo
could reduce coordination overhead, but would require a deliberate migration of
registration paths, release automation and contributor history; the RC does not
need that disruption to provide robust Julia bindings.

## Patch release before the next series

Finish the 0.11-compatible Julia companion and the PowerIO 0.11.10 release,
including Julia's artifact tests and registration, before merging the 0.12
companion into Julia `main`. The Rust candidate tag tests Julia `main`, so that
companion must then land before the 0.12 RC tag. The patch changes are merged
into the RC branches before final CI. Prerelease Rust tags do not publish a
registered Julia release; the final release does.

## Testing a release candidate

The development branch keeps `Project.toml` and `Artifacts.toml` at the last
stable package release until the stable release workflow updates them. Its
generated header can already require the next native release series. Thus
`Pkg.status()` alone does not identify the native candidate, and the old
artifact is not a compatible default for a new-series RC checkout. Record both
the exact Julia companion commit and `PowerIO.library_version()` when reporting
results.

After the candidate's [PowerIO release](https://github.com/eigenergy/powerio/releases)
is published, download its `libpowerio_capi.<triplet>.tar.gz` for your platform
and extract it. Install the exact Julia companion commit recorded for that
candidate into a separate environment, and set `POWERIO_CAPI` before importing
PowerIO. Replace the commit and library path in this example:

```julia
using Pkg
Pkg.activate("powerio-rc")
Pkg.add(url="https://github.com/eigenergy/PowerIO.jl", rev="FULL_JULIA_COMMIT")
ENV["POWERIO_CAPI"] = "/absolute/extracted/path/lib/libpowerio_capi.so"
using PowerIO
@assert PowerIO.library_version() == "0.12.0-rc.1"
Pkg.test("PowerIO")
```

Use `lib/libpowerio_capi.dylib` on macOS and
`bin/libpowerio_capi.dll` on Windows. For an unpublished candidate, a matching
local C API build can supply the same override. Do not reuse a native library
from another release series or rely on the unchanged package version to select
one. Testing `rc.2` requires its own recorded companion commit and library;
update the assertion to the exact new version. Restart Julia when changing the
environment variable, or use `PowerIO.set_library!` for an explicit session
override.

The artifact updater also accepts canonical `vX.Y.Z-rc.N` tags (`N >= 1`) so
the Rust release workflow can validate and pin all five RC tarballs before
publication. It still checks the exact version string, release series, required
symbols and GridFM behavior. These temporary pins do not publish a Julia
registry version. The automated release selector ignores RCs, even if a
GitHub release is accidentally marked stable; the final `vX.Y.Z` release
updates the package version and artifact pins together.
