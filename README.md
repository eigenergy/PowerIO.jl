# PowerIO.jl

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/assets/powerio-logo.svg"
    alt="PowerIO logo"
    width="120"
  >
</p>

Julia bindings for [PowerIO](https://github.com/eigenergy/powerio), which reads
power system case files into a typed `Network`, writes them back, and converts
between formats. The Rust core does the parsing and the byte-exact write, so a
case reads identically in Julia, Python, C/C++, and Rust.

Supported formats (each reads and writes, so any pair converts):

- [MATPOWER](https://matpower.org/) `.m`
- [PSS/E](https://www.siemens.com/global/en/products/energy/grid-software/planning/pss-software/pss-e.html) `.raw` revision 33
- [PowerWorld](https://www.powerworld.com/WebHelp/Content/MainDocumentation_HTML/Case_Formats.htm) `.aux`
- [PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl) network data JSON
- [egret](https://pypi.org/project/gridx-egret/) `ModelData` JSON
- [pandapower](https://www.pandapower.org/) network JSON

A same-format round trip is byte exact; cross-format conversion reports fields
the target cannot represent as warnings.

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/assets/powerio-hero.png"
    alt="PowerIO format and matrix flow"
    width="720"
  >
</p>

> **Status: registration in General in progress.** Once it completes,
> `Pkg.add("PowerIO")` needs no Rust toolchain; the binary downloads lazily on
> first use. Until then install from the repository URL below. See
> [docs/binary.md](docs/binary.md).

## Install

```julia
pkg> add PowerIO                  # once registration in General completes
pkg> add https://github.com/eigenergy/PowerIO.jl   # works either way
```

Working on the binding itself needs a local C ABI build; see Develop below.

## Use

```julia
using PowerIO

net = parse_file("case14.m")
PowerIO.n_buses(net), PowerIO.n_gens(net), PowerIO.base_mva(net)
PowerIO.source_format(net)        # "Matpower"
PowerIO.reference_bus_id(net)     # the slack bus id (or nothing)

text, warnings = convert_file("case14.m", "psse")

# egret and PowerModels both use .json; pass `from` to disambiguate:
egret = parse_file("grid.json"; from="egret")
```

`parse_file` also reads from an `IO`; a `String` argument is always a path, so
in-memory text goes through an `IO` or `parse_str` with an explicit format:

```julia
net = parse_file(IOBuffer(read("case14.m", String)), "matpower")
net = parse_str(read("case14.m", String), "matpower")
```

Serialization and the structured transport:

```julia
to_matpower(net)                   # ::String, byte exact when the input was MATPOWER
to_json(net)                       # the JSON transport
to_format(net, "powermodels-json") # (text, warnings)
from_json(to_json(net))            # Network with a live handle
PowerIO.warnings(net)              # fidelity warnings the reader attached to net
```

`to_normalized` derives a computation-ready copy: powers per unit, angles in
radians, tap `0 → 1`, out-of-service and isolated elements dropped, buses
reindexed to a dense 1-based id space, bus types inferred:

```julia
norm = to_normalized(net)
PowerIO.source_format(norm)       # "Normalized"
```

`to_dense` returns the numeric tables as dense typed arrays straight from the
C ABI extractors (no JSON parse) for matrix assembly:

```julia
d = to_dense(net)                 # or to_dense("case14.m") for parse + extract
d.n, d.m, d.ng                    # bus / branch / generator counts
d.bus_ids                         # 1-based ids; row k of every per-bus table is bus_ids[k]
d.branch.from, d.branch.x         # branch endpoints and reactances
d.ref_bus_index, d.n_islands, d.is_radial
```

`to_arrow` brings one table across the Arrow C Data Interface (needs the library
built with `--features arrow`; `arrow_available()` reports it). By default it
returns a NamedTuple of **owned** Julia Vectors (Tables.jl-shaped, flows into
`Arrow.write`, `DataFrame`, etc.), so there is no lifetime caveat. `copy=false`
returns a zero-copy `ArrowTable` whose columns view the producer's memory; each
column roots the shared buffers, so a column extracted from the table stays
valid on its own, and `close(z)` frees the buffers without waiting for GC. For
the numeric tables alone, `to_dense` is a copy-free, `unsafe_wrap`-free fast
path (the C ABI fills Julia-owned buffers).

```julia
t = to_arrow(net, :branch)                  # :bus, :branch, :gen, :load, :shunt; owned columns
t.from, t.x, t.tap
z = to_arrow(net, :branch; copy=false)      # zero-copy views; close(z) releases eagerly
```

`read_gridfm` reads a gridfm-datakit Parquet dataset back into a `Network` — the
inverse of the gridfm writer, the ML→classical return leg (needs the library built
with `--features gridfm`; `gridfm_available()` reports it). The read is lossy but
power-flow-complete; what the schema can't round-trip comes back in `warnings`.

```julia
r = read_gridfm("out/case14/raw")              # (; network, scenario, warnings)
to_matpower(r.network)                         # gridfm → any classical format
reads = read_gridfm_scenarios("out/case14/raw")  # one result per scenario id
```

At first use the binding checks `pio_abi_version` against the version it targets
and refuses a stale or mismatched library with an error stating both versions.

## Interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` / `parse_ac_power_data` feeding `build_polar_opf` / `build_rect_opf` / `build_dcopf` |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| MATPOWER / PSS/E / PowerWorld / PowerModels JSON / egret | file | `parse_file` / `convert_file` |
| GridFM (gridfm-datakit Parquet) | in | `read_gridfm` / `read_gridfm_scenarios` |

The `parse_file` / `to_*` naming is shared across Rust, Python, Julia, and the
C ABI; the cross language table is in [docs/languages.md](docs/languages.md).

## Develop

With a sibling `powerio` checkout, build the C ABI and `using PowerIO` finds it:

```
# in the sibling powerio checkout (arrow enables to_arrow, gridfm enables read_gridfm):
cargo build -p powerio-capi --release --features arrow,gridfm
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
PowerIO.set_library!("/path/to/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`
```

Users never build Rust: released versions fetch the per-platform binary as a
lazy artifact. The pipeline is described in [docs/binary.md](docs/binary.md).

## Roadmap

0.1.0 ships the gridfm reader (`read_gridfm`) against powerio v0.1.0, with
registration in General underway. Next: a fully typed immutable `Network`
mirroring the Rust model (today's view is JSON-backed), a Documenter site,
package extensions for the PowerModels and ExaPowerIO bridges, and
distribution through a registered `PowerIO_jll`.

## License

MIT.
