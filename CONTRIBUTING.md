# Contributing

## Setup

PowerIO.jl wraps the powerio Rust library through its C ABI. Develop against a
sibling checkout; the library resolves automatically from
`../powerio/target/{release,debug}`:

```
git clone https://github.com/eigenergy/powerio ../powerio
(cd ../powerio && cargo build -p powerio-capi --release --features arrow,matrix,gridfm,dist,prob)
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

`POWERIO_CAPI=/path/to/libpowerio_capi.so` or `PowerIO.set_library!(path)`
override the resolution; without a development build, the bundled lazy
artifact is used.

## ABI lockstep

The binding targets exactly one C ABI version (7 for PowerIO 0.11); a
mismatched library is refused at first use with an error naming both versions.
Every `pio_*` entry point the binding calls appears as a Symbol literal in
`src/`, written `@capi lib :pio_name(args...)`, and powerio's
`scripts/check-capi-v7.sh` checks that list against the header, so a renamed
or removed entry point fails the powerio pull request that changed it.

`src/LibPowerIO.jl` declares the whole C ABI: every entry point, every view
struct, every opaque handle type, and the ABI number `PIO_ABI_VERSION` reads.
It is generated from the header, never edited by hand:

```
julia --project=gen -e 'using Pkg; Pkg.instantiate()'
julia --project=gen gen/generate.jl ../powerio/powerio-capi/include/powerio.h
```

Without the argument the generator reads `POWERIO_HEADER`, then a sibling
powerio checkout. Its output is deterministic, so an unchanged header
reproduces the file byte for byte, and CI regenerates against the powerio
branch under test and fails when the committed file is stale. When powerio
changes the header, rerun the generator, commit `src/LibPowerIO.jl`, adapt the
calls here, run the full suite against the matching powerio branch, and merge
the two changes back to back.

`test/test_capi_coverage.jl` requires every generated entry point to be either
called from `src/` or listed in `gen/unbound_entry_points.txt` with a reason,
so a newly added powerio entry point cannot pass through unnoticed.

Companion branches: a powerio pull request that changes the shared surface
pushes a PowerIO.jl branch with the same name, and powerio's Julia binding job
tests against it. `.github/powerio-companion` names the powerio branch this
branch is tested against when no same named branch exists.

## Memory safety conventions

Every pointer from the C library is owned by a finalizer backed handle type
(`src/handles.jl`), and every value handed to Julia code is copied out of the
borrowed C views before the call returns. Keep new call sites inside this
pattern: run the call under `GC.@preserve` of the handle, and never let an
`unsafe_wrap` of library memory escape. See the memory safety page in the
documentation.

## Releasing

Use the [paired release procedure](https://github.com/eigenergy/powerio/blob/main/docs/src/paired-releases.md).
It prepares both repositories for one publication approval and registers the
exact tested Julia commit independently of later changes to `main`.

Until paired automation is activated after v0.11.2, follow the existing
version, changelog, release-intent, and tag workflow. Do not mix the two
release routes. The legacy intent is not a Julia requirement and is not used
by paired releases.

## Writing

Comments and documentation state what the code does and why it is correct,
in plain words: no history of how it came to be, no first person, no em
dashes, no filler.

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
