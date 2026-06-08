# PowerIO.jl

Julia bindings for [PowerIO](https://github.com/eigenergy/powerio): a lossless
reader/writer for power system case files. Parse MATPOWER, PSS/E, PowerWorld,
PowerModels JSON, and EGRET JSON; all five read and write, so any pair converts
(byte-exact on a same-format round-trip, maximal-fidelity across formats). Hand the
data to the Julia modeling and solver packages you already use.

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

With a sibling `powerio` checkout (`PowerIO.jl` and `powerio` in the same parent
directory), build the C ABI and `using PowerIO` finds it — no env var, no
`set_library!`:

```
# in the sibling powerio checkout:
cargo build -p powerio-capi --release        # → target/release/libpowerio_capi.{dylib,so}
```

```julia
using PowerIO                                 # auto-discovers ../powerio/target/{release,debug}
net = parse_case("case14.m")
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
using PowerIO
PowerIO.set_library!("/path/to/powerio/target/release/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`

net = parse_case("case14.m")
PowerIO.n_buses(net), PowerIO.n_gens(net), PowerIO.base_mva(net)
PowerIO.source_format(net)        # "Matpower"
PowerIO.reference_bus_id(net)     # the slack bus id (or nothing)

text, warnings = convert_case("case14.m", "psse")

# EGRET and PowerModels both use .json — pass `from` to disambiguate:
egret = parse_case("grid.json"; from="egret")
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
| MATPOWER / PSS/E / PowerWorld / PowerModels JSON / EGRET | file (read+write, any pair) | the Rust core's readers/writers via `parse_case` / `convert_case` | now |

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
  surface and a dense-extraction fast path (the C ABI already exposes
  `pio_bus_ids`/`pio_branches`/`pio_gens`/`pio_nodal_demand`/`pio_nodal_shunt` and
  `pio_reference_bus`/`pio_n_components`/`pio_is_radial` — these need a retained
  case handle, so they land here, not in v0.0.1).
- PowerModels parity: `to_powermodels`/`from_powermodels`, same objective as
  `PowerModels.parse_file`.
- ExaPowerIO/ExaModelsPower: `to_powerdata` (a `PowerData`) + a `parse_ac_power_data`
  NamedTuple feeding `build_polar_opf`/`build_rect_opf`/`build_dcopf`.
- Clang.jl-seeded `ccall` layer over `powerio.h`.
- Yggdrasil `PowerIO_jll` swap; Documenter site + a CI job that rebuilds from the
  local Rust tree.

**v0.2.0 and beyond.** PowerModelsDistribution / OpenDSS, more in-memory ecosystem
bridges, further formats.

## License

MIT.
