# Contributing

## Setup

PowerIO.jl wraps the powerio Rust core through its C ABI. Develop against a
sibling checkout; the library resolves automatically from
`../powerio/target/{release,debug}`:

```
git clone https://github.com/eigenergy/powerio ../powerio
cargo build -p powerio-capi --release --features arrow,matrix,gridfm,dist,pkg,prob   # in ../powerio
julia --project=. -e 'using Pkg; Pkg.test()'
```

`POWERIO_CAPI=/path/to/libpowerio_capi.dylib` or `PowerIO.set_library!(path)`
override the resolution; without a dev build, the bundled lazy artifact is used.

## ABI lockstep

The binding targets exactly one core C ABI version (`PIO_ABI_VERSION` in
`src/capi.jl`); a mismatched library is refused at first use with an error
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
   without changing the tree;
   a dispatch for another tag is ignored.
2. Runs `gen/update_artifacts.jl` in memory, then checks core ABI 5,
   distribution ABI 1, the schema and build reports, and the `arrow`, `matrix`,
   `gridfm`, `dist`, `pkg`, and `prob` features and representative symbols.
   Semantic mismatches report a stable `parked` reason and leave
   `Artifacts.toml` byte identical. Download, registry, archive, or parse
   errors fail the run.
3. Resolves the generated artifact, checks every public feature probe, and
   runs the full test suite. It commits only `Artifacts.toml`, and pushes only
   if `origin/main` still equals the commit the run tested. A race fails; the
   schedule retries from the new main without rebasing a bot commit.
4. Dispatches "Register Package" with the exact tested SHA. Registration
checks that the SHA is still `origin/main`, revalidates the intent, artifact,
release, General transition, feature reports, and tests, then posts the
`@JuliaRegistrator register` comment on that SHA. It never edits or commits,
and queued retries suppress a duplicate bot comment for six hours.

The intended version must be the next patch, minor, or major release after the
maximum PowerIO version in General. A breaking transition needs "breaking" in
its top changelog section. If the version is already in General,
the updater neither repins nor registers; it dispatches TagBot only when the
Julia GitHub release is missing. Registration also makes that intent terminal:
later development can change the source digest without breaking the scheduled
job or the TagBot repair path.

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

## Docs

Documenter build: `julia --project=docs docs/make.jl`.
