# Contributing

## Setup

PowerIO.jl wraps the powerio Rust core through its C ABI. Develop against a
sibling checkout; the library resolves automatically from
`../powerio/target/{release,debug}`:

```
git clone https://github.com/eigenergy/powerio ../powerio
cargo build -p powerio-capi --release --features arrow,gridfm,dist,pkg   # in ../powerio
julia --project=. -e 'using Pkg; Pkg.test()'
```

`POWERIO_CAPI=/path/to/libpowerio_capi.dylib` or `PowerIO.set_library!(path)`
override the resolution; without a dev build, the bundled lazy artifact is used.

## ABI lockstep

The binding targets exactly one core C ABI version (`PIO_ABI_VERSION` in
`src/PowerIO.jl`); a mismatched library is refused at first use with an error
stating both versions. The distribution surface has its own
`PIO_DIST_ABI_VERSION` in `src/dist.jl`. The package surface is additive and
feature probed through `pio_package_*`; no third ABI integer is used. When
powerio bumps either ABI, update the matching constant and any renamed ccalls
here, verify the full suite against the matching powerio branch, and merge the
two changes back to back. The ABI history is in powerio's
`powerio-capi/README.md`.

## Memory safety conventions

Every pointer from the C ABI is owned by a finalizer-backed handle
(`NetworkHandle`) or copied out before the producer is released. `to_arrow`
returns owned columns by default; the zero-copy path (`copy=false`) is opt-in
and documented on `ArrowTable`. Keep new ccall sites inside this pattern:
no `unsafe_wrap` of foreign memory escapes without an owner.

## Releasing

After each powerio binary release:

1. Dispatch the "Update artifacts" workflow with the new powerio tag. It
   regenerates Artifacts.toml from the release tarballs and opens a PR when
   anything changed. The updater checks both `PIO_ABI_VERSION` and
   `PIO_DIST_ABI_VERSION` before rewriting `Artifacts.toml`; if either changed,
   update the matching constant and affected ccalls in that PR (see "ABI
   lockstep" above).
2. Merge the artifacts PR if one was opened, then dispatch "Register Package"
   with the new version (no leading v, or major/minor/patch to bump) and, for a
   breaking bump, release notes. It commits the Project.toml bump to main and
   posts the `@JuliaRegistrator register` comment with a `Release notes:` block
   (defaulting to the top CHANGELOG.md section); the manual fallback is
   commenting that — notes block included — on any commit.

   Every pre-1.0 minor bump (`0.x.0`) is a *breaking* release, and General's
   AutoMerge holds a breaking version whose trigger has no change description.
   The notes must mention "breaking" or "changelog" (even just "no breaking
   changes"); the workflow's CHANGELOG default already does.
3. The General registry PR AutoMerges in about 15 minutes for new versions
   (3 days for a brand-new package). TagBot then tags `vX.Y.Z` here and
   creates the GitHub release.

   TagBot uses `TAGBOT_TOKEN` when present, falling back to `GITHUB_TOKEN` for
   normal releases. Set `TAGBOT_TOKEN` to a fine grained token with contents and
   workflows write access before asking TagBot to backfill old versions whose
   registered commits changed `.github/workflows/*.yml`. Set `TAGBOT_SSH` to a
   write deploy key, or reuse `DOCUMENTER_KEY`, so TagBot can push release tags
   through SSH.

A binding-only fix (no new binary) skips step 1.

Version numbers: a binary-driven release registers the powerio version it wraps
when that number is still free, otherwise the next patch; a binding-only release
bumps the patch independently. The ABI checks (`PIO_ABI_VERSION` and
`PIO_DIST_ABI_VERSION`) decide whether a binary is usable, not the version number.

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
