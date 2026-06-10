# Contributing

## Setup

PowerIO.jl wraps the powerio Rust core through its C ABI. Develop against a
sibling checkout; the library resolves automatically from
`../powerio/target/{release,debug}`:

```
git clone https://github.com/eigenergy/powerio ../powerio
cargo build -p powerio-capi --release --features arrow   # in ../powerio
julia --project=. -e 'using Pkg; Pkg.test()'
```

`POWERIO_CAPI=/path/to/libpowerio_capi.dylib` or `PowerIO.set_library!(path)`
override the resolution; without a dev build, the bundled lazy artifact is used.

## ABI lockstep

The binding targets exactly one C ABI version (`PIO_ABI_VERSION` in
`src/PowerIO.jl`); a mismatched library is refused at first use with an error
stating both versions. When powerio bumps its ABI, update the constant and any
renamed ccalls here, verify the full suite against the matching powerio branch,
and merge the two changes back to back. The ABI history is in
powerio's `powerio-capi/README.md`.

## Memory safety conventions

Every pointer from the C ABI is owned by a finalizer-backed handle
(`NetworkHandle`) or copied out before the producer is released. `to_arrow`
returns owned columns by default; the zero-copy path (`copy=false`) is opt-in
and documented on `ArrowTable`. Keep new ccall sites inside this pattern:
no `unsafe_wrap` of foreign memory escapes without an owner.

## Releasing

After each powerio binary release:

1. Dispatch the "Update artifacts" workflow with the new powerio tag. It
   regenerates Artifacts.toml from the release tarballs and opens a PR. If the
   release bumped `PIO_ABI_VERSION`, update the constant and the affected
   ccalls in that PR (see "ABI lockstep" above).
2. Merge the PR, then dispatch "Register Package" with the new version (or
   major/minor/patch to bump). It commits the Project.toml bump to main and
   posts the `@JuliaRegistrator register` comment; the manual fallback is
   commenting that on any commit.
3. The General registry PR AutoMerges in about 15 minutes for new versions
   (3 days for a brand-new package). TagBot then tags `vX.Y.Z` here and
   creates the GitHub release.

A binding-only fix (no new binary) skips step 1.

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
