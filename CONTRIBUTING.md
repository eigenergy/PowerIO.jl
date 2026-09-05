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

The binding targets exactly one C ABI version (`PIO_ABI_VERSION` in
`src/capi.jl`, 7 for PowerIO 0.11); a mismatched library is refused at first
use with an error naming both versions. Every `pio_*` entry point the binding
calls appears as a Symbol literal in `src/`, and powerio's
`scripts/check-capi-v7.sh` checks that list against the header, so a renamed
or removed entry point fails the powerio pull request that changed it. When
powerio bumps the ABI, update the constant, the struct mirrors in
`src/views.jl`, and the renamed calls here, run the full suite against the
matching powerio branch, and merge the two changes back to back.

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

The release is approved before powerio publishes. Put the intended PowerIO
version in `Project.toml`, write the matching top `CHANGELOG.md` section, and
merge every Julia source, documentation, and workflow change. Leave
`.github/powerio-release.toml` in `state = "draft"` while that work is moving.
From a clean final `main`, run:

```
julia --project=. gen/release_state.jl prepare-intent
```

Review and merge that one file intent change last. It records the exact Julia
version, exact powerio tag, and a SHA-256 digest of every tracked path, mode,
object type, and object id except `Artifacts.toml` and the intent itself. Any
later source, documentation, or workflow commit makes the digest stale and
parks the release until a new intent is reviewed.

Publishing the intended powerio release triggers "Update artifacts"; the daily
schedule and a no input manual dispatch retry the same intent. The workflow:

1. Requires the exact published powerio release, which must not be a
   prerelease, and all five platform assets. A missing or draft release waits
   without changing the tree; a dispatch for another tag is ignored.
2. Runs `gen/update_artifacts.jl` in memory. It loads the host library and
   checks the ABI number, the version string against the tag, the core entry
   points the binding calls, and that the library parses the GridFM fixture.
   A mismatch reports a stable `parked` reason and leaves `Artifacts.toml`
   byte identical. Download, registry, archive, or parse errors fail the run.
3. Resolves the generated artifact and runs the full test suite. It commits
   only `Artifacts.toml`, and pushes only if `origin/main` still equals the
   commit the run tested. A race fails; the schedule retries from the new main
   without rebasing a bot commit.
4. Dispatches "Register Package" with the exact tested SHA. Registration
   checks that the SHA is still `origin/main`, revalidates the intent,
   artifact, release, General transition, and tests, then posts the
   `@JuliaRegistrator register` comment on that SHA. It never edits or
   commits, and queued retries suppress a duplicate bot comment for six hours.

The intended version must be the next patch, minor, or major release after the
maximum PowerIO version in General. A breaking transition needs "breaking" in
its top changelog section. If the version is already in General, the updater
neither repins nor registers; it dispatches TagBot only when the Julia GitHub
release is missing. Registration also makes that intent terminal: later
development can change the source digest without breaking the scheduled job
or the TagBot repair path.

For local generator diagnostics, supply a status path explicitly:

```
julia --project=. gen/update_artifacts.jl vX.Y.Z --status-file update-status.toml
```

The status is `ready` or `parked`; only `ready` can modify `Artifacts.toml`.
Manual workflow dispatch is a retry, not a release authority override. An open
`artifacts/*` PR makes the automatic run wait rather than release around it.

If Registrator has not replied on the exact release commit within about 15
minutes, rerun "Register Package" with the version and that full SHA. The last
resort is a human `@JuliaRegistrator register` comment with the top changelog
section as its `Release notes:` block.

TagBot uses `TAGBOT_TOKEN` when present, falling back to `GITHUB_TOKEN` for
normal releases. Issue #44 is a manual `v0.0.1` backfill because the tagged
commit changed workflow files. To resolve it, create a fine grained
`TAGBOT_TOKEN` with contents and workflows write access, add it as a repo
Actions secret, then run the TagBot workflow manually. If that still fails,
run `gh release create v0.0.1 --target a6a9b00a --generate-notes` locally.
Set `TAGBOT_SSH` to a write deploy key, or reuse `DOCUMENTER_KEY`, so TagBot
can push release tags through SSH.

## Writing

Comments and documentation state what the code does and why it is correct,
in plain words: no history of how it came to be, no first person, no em
dashes, no filler.

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
