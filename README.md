# PowerIO.jl

Julia bindings for [PowerIO](https://github.com/eigenergy/powerio): a fast, lossless
reader/writer for power system case files. Parse MATPOWER, PSS/E, PowerWorld, and
PowerModels JSON, convert losslessly between them, and hand the data to the Julia
modeling and solver packages you already use.

PowerIO.jl is a thin wrapper over the PowerIO Rust core through its C ABI
(`powerio-capi`). It holds an opaque case handle, calls `pio_to_json` once, and
materializes an immutable `Network`; every accessor and every ecosystem bridge is
then pure Julia. The Rust core does the parsing and the byte-exact write, so a
case reads identically in Julia, Python, C/C++, and Rust.

> **Status: scaffold.** The package structure, C ABI layer, accessors, and milestone
> plan are here; it is not yet registered. During development the binary is wired
> through a local library path (below). For the public release it ships as a
> self-hosted, lazy artifact — per-platform tarballs on a GitHub release, referenced
> from `Artifacts.toml` — so PowerIO registers in General with **no Rust toolchain**
> and a plain `Pkg.add("PowerIO")`. A Yggdrasil `PowerIO_jll` is a later, non-blocking
> swap.

## Develop (before `PowerIO_jll` exists)

Build the C ABI from the PowerIO Rust tree and point Julia at it:

```
# in the PowerIO repo:
cargo build -p powerio-capi --release        # → target/release/libpowerio_capi.{dylib,so}
```

```julia
using PowerIO
PowerIO.set_library!("/path/to/PowerIO/target/release/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`

net = parse_case("case14.m")
PowerIO.n_buses(net), PowerIO.base_mva(net)
text, warnings = convert_case("case14.m", "psse")
```

## Shipping the binary

`deps/build.jl` would run `cargo` on every user's machine and demand a Rust
toolchain — the deprecated path. Instead the Rust `cdylib` is cross-compiled
**once** with BinaryBuilder (see `gen/build_tarballs.jl`) and the per-platform
tarballs are published on a GitHub release. PowerIO references them from a lazy
`Artifacts.toml`, so it has no unregistered dependency and registers in General;
Julia's artifact system downloads the right tarball on first use, no Rust toolchain.
A Yggdrasil `PowerIO_jll` is the eventual canonical form — a one-line `_lib()` swap —
but it does not gate the release. The maintainer's local `cargo build` is only a dev
override (above), never a user step.

## Interop

Native, in-memory bridges to the Julia ecosystem. The PowerModels and
ExaPowerIO/ExaModelsPower bridges are weak-dependency extensions, so you only pay
for what you load; PowerDiff instead hard-deps PowerIO and adapts the `Network` on
its own side.

| Target | Direction | Mechanism | Milestone |
|---|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` (the post-parse, pre-`correct_network_data!` dict) | v0.1.0 |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` (an ExaPowerIO `PowerData`) + a `parse_ac_power_data` NamedTuple feeding `build_polar_opf` / `build_rect_opf` / `build_dcopf` | v0.1.0 |
| PowerDiff.jl | out | PowerDiff hard-deps PowerIO; its `:powerio` backend adapts the `Network` (PowerIO ships the accessors) | done |
| MATPOWER / PSS/E / PowerModels JSON / EGRET | file | the Rust core's readers/writers | now |

## Milestones

The C ABI keystone (`pio_to_json`/`pio_from_json`, the typed `Network` serializer)
is done in the Rust core.

**v0.0.1 — public release (installable, PowerDiff-ready).**
- Self-hosted lazy `Artifacts.toml` for `libpowerio_capi` → register in General,
  decoupled from Yggdrasil.
- Minimal `Network` accessor surface the ecosystem bridges read.
- PowerDiff hard-deps PowerIO via its `:powerio` backend, parity-tested against
  `:native` (done).

**v0.1.0 — ecosystem parity + canonical JLL.**
- Typed immutable `Network` mirroring `powerio/src/network.rs` + the full accessor
  surface and a dense-extraction fast path.
- PowerModels parity: `to_powermodels`/`from_powermodels`, same objective as
  `PowerModels.parse_file`.
- ExaPowerIO/ExaModelsPower: `to_powerdata` (a `PowerData`) + a `parse_ac_power_data`
  NamedTuple feeding `build_polar_opf`/`build_rect_opf`/`build_dcopf`.
- Clang.jl-seeded `ccall` layer over `powerio.h`.
- Yggdrasil `PowerIO_jll` swap; Documenter site + a CI job that rebuilds from the
  local Rust tree.

**v0.2.0 and beyond.** PowerModelsDistribution / OpenDSS, EGRET round-trip, more formats.

## License

MIT.
