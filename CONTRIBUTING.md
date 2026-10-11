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

PowerIO.jl X.Y.Z pairs with powerio vX.Y.Z, and the "Release" workflow
releases it after powerio publishes vX.Y.Z. There is no separate PowerIO.jl
release step.

- Write user facing changes under a `## Unreleased` heading at the top of
  `CHANGELOG.md`, and leave the version in `Project.toml` alone.
- Publishing a powerio release releases PowerIO.jl. The workflow sets the
  version, renames `## Unreleased` to `## X.Y.Z` (or adds a section that
  points to the powerio changelog when there are no notes), pins the release
  binaries in `Artifacts.toml`, runs the full test suite against them, pushes
  the release commit to `main`, and comments `@JuliaRegistrator register` on
  it with that section as the release notes. TagBot tags the version and
  creates its GitHub release after General merges it.
- A `## X.Y.Z` section written before the release is kept. Notes under a
  non-empty `## Unreleased` beside it fail the run, because the release is
  built from `main`, which holds those changes: move them into `## X.Y.Z`.
- A patch release fails when its changelog section marks a change as
  breaking: a `### Breaking` heading, a `Breaking:` label, or `(breaking)`.
- Every PowerIO.jl version pairs with the powerio release of the same number,
  so do not register a PowerIO.jl version by hand. While General's latest
  PowerIO version has no published powerio release, every run fails. A
  binding only fix ships with a powerio patch release.

A failed run states its reason on the run page. The workflow also runs every
hour, so after fixing the cause, wait for the next run or start one with
"Run workflow" on "Release". A run does not repeat a registration request
made within the last six hours on any commit since `Project.toml` took the
version. When JuliaRegistrator answered that request with an error, a run
on the same commit fails with the answer, and a run on a newer commit
requests that commit. When AutoMerge fails on the General pull request, fix
the cause on `main`: the next run requests registration of the new commit,
and Registrator updates the pull request. The `dry_run` input prepares and
tests without pushing or registering, and a run started from any branch
other than `main` is always a dry run.

To keep `main` from being released, set the repository variable
`RELEASE_HOLD` to `true` before powerio publishes; the hourly runs and the
run powerio's publish starts are then skipped, and only "Run workflow" runs.
Delete the variable once the version is registered. To release an earlier commit, set
`source_sha` to it: the run builds the release commit on that commit and
pushes it to `release/vX.Y.Z` instead of `main`. The run uses that commit's
`gen/release.jl`, so the commit must include it. The workflow token cannot
create a branch whose `.github/workflows` differs from `main`'s, so in that
case push the commit to `release/vX.Y.Z` yourself first; the run then adds
the release commit on top.

TagBot uses `TAGBOT_TOKEN` when present, falling back to `GITHUB_TOKEN`. Set
`TAGBOT_SSH` to a write deploy key, or reuse `DOCUMENTER_KEY`, so TagBot can
push release tags through SSH.

## Writing

Comments and documentation state what the code does and why it is correct,
in plain words: no history of how it came to be, no first person, no em
dashes, no filler.

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
