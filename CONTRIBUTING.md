# Contributing

## Setup

PowerIO.jl wraps the powerio Rust core through its C ABI. Develop against a
sibling checkout; the library resolves automatically from
`../powerio/target/{release,debug}`:

```
git clone https://github.com/eigenergy/powerio ../powerio
cargo build -p powerio-capi --release --features arrow,matrix,gridfm,dist,pkg   # in ../powerio
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
(`BalancedNetworkHandle`, `MulticonductorNetworkHandle`) or copied out before the producer is released. `to_arrow`
returns owned columns by default; the zero-copy path (`copy=false`) is opt-in
and documented on `ArrowTable`. Keep new ccall sites inside this pattern:
no `unsafe_wrap` of foreign memory escapes without an owner.

## Releasing

Binary-driven releases are hands-off. When powerio publishes a release (its
Notify PowerIO.jl workflow fires a repository dispatch; a daily scheduled run
is the backstop), the "Update artifacts" workflow:

1. Regenerates Artifacts.toml from the release tarballs. The updater checks
   both `PIO_ABI_VERSION` and `PIO_DIST_ABI_VERSION` before rewriting
   `Artifacts.toml`, and checks the arrow, matrix, gridfm, dist, and package
   surfaces; an ABI-bumping release parks untouched until the lockstep
   binding PR merges (see "ABI lockstep" above), and the next scheduled run
   picks it up. The automatic path never downgrades the pin: reverting to an
   older tag (or pinning a prerelease) requires the `open_pr` input.
2. Decides the version, prepends the CHANGELOG.md section, and sets
   Project.toml — the version is the powerio version it wraps when that
   number is ahead of Project.toml, otherwise the next patch; the ABI checks
   decide whether a binary is usable, not the version number.
3. Runs the full test suite against that exact tree (including the
   `test_release.jl` changelog/version consistency check), then commits the
   repin, changelog, and version bump to main as one atomic commit.
4. Dispatches "Register Package", which posts the `@JuliaRegistrator
   register` comment with a `Release notes:` block (the top CHANGELOG.md
   section). The General registry PR AutoMerges in about 15 minutes for new
   versions; TagBot then tags `vX.Y.Z` here and creates the GitHub release.

The pipeline self-heals by checking General's Versions.toml: a scheduled run
that finds Project.toml's version unregistered re-dispatches registration,
and one that finds the pinned powerio tag or top CHANGELOG.md section ahead
of Project.toml rebuilds and commits the missing release state — so a lost
dispatch, a failed register run, or a repin merged without registration all
resolve by the next scheduled run.

For a binding-only release (no new binary), bump Project.toml and add the
matching top CHANGELOG.md section in the same PR (the release metadata test
enforces that they agree), and merge it. The nightly run notices the version
is not in General and registers it; dispatch "Register Package" with that
version to register immediately. Every pre-1.0 minor bump (`0.x.0`) is a
*breaking* release, and General's AutoMerge holds a breaking version whose
trigger has no change description: the notes must mention "breaking" or
"changelog" (even just "no breaking changes"); the generated CHANGELOG
entries already do, and the workflows fail fast when a human-written section
does not.

To review a repin instead of auto-releasing it, dispatch "Update artifacts"
with `open_pr`: the same repin + changelog + version bump opens as a PR (a
tag that is not plain vX.Y.Z always takes the PR path), and the automatic
release path stands down while an `artifacts/*` PR is open. Note CI does not
run on pushes or PRs made with the workflow token; the test suite runs
inside the workflow before anything lands.

Manual registration fallback: comment `@JuliaRegistrator register` — with the
`Release notes:` block — on any commit. If Registrator has not replied on the
commit thread within ~15 minutes, the bot-authored comment was dropped; post
the same comment from a human account.

TagBot uses `TAGBOT_TOKEN` when present, falling back to `GITHUB_TOKEN` for
normal releases. Issue #44 is a manual `v0.0.1` backfill because the tagged
commit changed workflow files. To resolve it, create a fine grained
`TAGBOT_TOKEN` with contents and workflows write access, add it as a repo
Actions secret, then run the TagBot workflow manually. If that still fails,
run `gh release create v0.0.1 --target a6a9b00a --generate-notes` locally.
Set `TAGBOT_SSH` to a write deploy key, or reuse `DOCUMENTER_KEY`, so TagBot
can push release tags through SSH.

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
