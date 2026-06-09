# PowerIO.jl

Julia bindings for [PowerIO](https://github.com/eigenergy/powerio): a lossless
reader/writer for power system case files. Parse MATPOWER, PSS/E, PowerWorld,
PowerModels JSON, and EGRET JSON; all five read and write, so any pair converts
(byte-exact on a same-format round-trip, maximal-fidelity across formats). Hand the
data to the Julia modeling and solver packages you already use.

PowerIO.jl is a thin wrapper over the PowerIO Rust core through its C ABI
(`powerio-capi`). The Rust core does the parsing and the byte-exact write, so a
case reads identically in Julia, Python, C/C++, and Rust. Parse once with
`parse_file` (a path, or an `IO`) into an immutable `Network`, then read or transform
it:

- the rich, lossless element tables (every field, costs, storage, HVDC) via the
  accessors and `to_json`.
- `to_dense` → the numeric tables as dense typed arrays for matrix assembly,
  straight from the C ABI extractors (no JSON).
- `to_arrow` → one table zero-copy over the Arrow C Data Interface.
- `to_normalized` → a per-unit / radian / filtered / reindexed copy; `to_matpower`
  and `convert_file` serialize back out.

Every `to_*` reads a parsed `Network` straight off its retained handle (no re-parse),
or takes a path for a one-shot.

At first use the binding checks the library's ABI version (`pio_abi_version`)
against the version it targets and refuses a stale or mismatched library with a
directed error.

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
net = parse_file("case14.m")
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
using PowerIO
PowerIO.set_library!("/path/to/powerio/target/release/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`

net = parse_file("case14.m")
PowerIO.n_buses(net), PowerIO.n_gens(net), PowerIO.base_mva(net)
PowerIO.source_format(net)        # "Matpower"
PowerIO.reference_bus_id(net)     # the slack bus id (or nothing)

text, warnings = convert_file("case14.m", "psse")

# EGRET and PowerModels both use .json — pass `from` to disambiguate:
egret = parse_file("grid.json"; from="egret")
```

`parse_file` also reads from an `IO` — a `String` is always a path, so pass case text
in memory through an `IO` with an explicit `format`:

```julia
net = parse_file(IOBuffer(read("case14.m", String)), "matpower")
```

`to_normalized` derives a computation-ready copy: powers per unit (÷ `base_mva`),
angles in radians, transformer tap `0 → 1`, out-of-service and isolated elements
dropped, buses reindexed to a dense 1-based id space, and bus types inferred (a
generator bus keeps `REF` or becomes `PV`, a generator-less bus becomes `PQ`):

```julia
norm = to_normalized(net)
PowerIO.source_format(norm)       # "Normalized"
PowerIO.base_mva(norm)            # unchanged; the element tables are now per unit
```

`to_matpower` serializes a case back to MATPOWER `.m` text (byte-exact when the input
was MATPOWER); `to_json` gives the JSON transport:

```julia
to_matpower(net)                  # ::String
to_json(net)                      # ::String
```

For matrix assembly, `to_dense` returns the numeric tables as dense typed arrays
straight from the C ABI — bus ids, branch and generator tables, per-bus demand and
shunt, plus the connectivity scalars — no JSON parse:

```julia
d = to_dense(net)                 # or to_dense("case14.m") to parse + extract in one shot
d.n, d.m, d.ng                    # bus / branch / generator counts
d.bus_ids                         # 1-based ids; row k of every per-bus table is bus_ids[k]
d.branch.from, d.branch.x         # branch endpoints (1-based ids) and reactances
d.reference_bus, d.n_components, d.is_radial
```

`to_arrow` lends one table zero-copy over the Arrow C Data Interface (needs the
library built `--features arrow`; `arrow_available()` reports whether it is). The
columns are a Tables.jl-shaped NamedTuple, so they flow into `Arrow.write`,
`DataFrame`, etc. Keep the returned `ArrowTable` alive while reading its columns —
they view the producer's memory:

```julia
cargo build -p powerio-capi --release --features arrow   # in the sibling powerio checkout
```

```julia
t = to_arrow(net, :branch)        # :bus, :branch, :gen, :load, :shunt
t.from, t.x, t.tap                # zero-copy column views
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
| MATPOWER / PSS/E / PowerWorld / PowerModels JSON / EGRET | file (read+write, any pair) | the Rust core's readers/writers via `parse_file` / `convert_file` | now |

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
- Dense-extraction fast path (`to_dense`) over `pio_bus_ids`/`pio_branches`/
  `pio_gens`/`pio_nodal_demand`/`pio_nodal_shunt` + `pio_reference_bus`/
  `pio_n_components`/`pio_is_radial`, the zero-copy Arrow export (`to_arrow` over
  the Arrow C Data Interface), and the load-time ABI version handshake
  (`pio_abi_version`): **done.** A fully typed immutable `Network` mirroring
  `powerio/src/network.rs` (today the `Network` view is JSON-backed) is the
  remaining piece.
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
