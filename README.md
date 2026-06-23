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

A same-format round trip is byte exact; cross-format conversion reports fields
the target cannot represent as warnings.

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/assets/powerio-hero.png"
    alt="PowerIO format and matrix flow"
    width="720"
  >
</p>

## Install

```julia
pkg> add PowerIO
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
```

`to_normalized` derives a computation-ready copy: powers per unit, angles in
radians, tap `0 → 1`, out-of-service and isolated elements dropped, source bus
ids preserved, bus types inferred:

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
d.reference_bus, d.n_components, d.is_radial
```

`to_arrow` brings one table across the Arrow C Data Interface (needs the library
built with `--features arrow`; `arrow_available()` reports it). By default it
returns a NamedTuple of **owned** Julia Vectors (Tables.jl-shaped, flows into
`Arrow.write`, `DataFrame`, etc.), so there is no lifetime caveat. `copy=false`
returns a zero-copy `ArrowTable` whose columns view the producer's memory; keep it
alive while reading them. For the numeric tables alone, `to_dense` is a copy-free,
`unsafe_wrap`-free fast path (the C ABI fills Julia-owned buffers).

```julia
t = to_arrow(net, :branch)                  # :bus, :branch, :gen, :load, :shunt; owned columns
t.from, t.x, t.tap
z = to_arrow(net, :branch; copy=false)      # zero-copy views; keep `z` alive while reading
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

Multiconductor distribution cases are a separate model on their own `DistNetwork`
handle (OpenDSS `"dss"`, PowerModelsDistribution ENGINEERING JSON `"pmd"`, IEEE
BMOPF JSON `"bmopf"`; needs the library built with `--features dist`, on by default
in the released binaries; `dist_available()` reports it and checks
`PIO_DIST_ABI_VERSION == 1`). Experimental while the BMOPF schema is v0.0.1. It
shares the transmission verbs: `to_format` and `warnings` dispatch on the handle,
and the entry points take `DistNetwork` first, the `parse(T, x)` idiom — Julia
dispatches on argument types, not the return type.

```julia
dn = parse_file(DistNetwork, "feeder.dss")               # ::DistNetwork
text, warnings = to_format(dn, "pmd")                    # serialize; same-format write is byte exact
dss, _ = convert_file(DistNetwork, "feeder.dss", "bmopf")  # one-shot convert
PowerIO.warnings(dn)                                     # fidelity warnings retained on the handle
```

At first use the binding checks `pio_abi_version` against the core ABI version it
targets and refuses a stale or mismatched library with an error stating both
versions. Distribution entry points also check `pio_dist_abi_version` before
calling `pio_dist_*`.

## Interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` / `parse_ac_power_data` feeding `build_polar_opf` / `build_rect_opf` / `build_dcopf` |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| MATPOWER / PSS/E / PowerWorld / PowerModels JSON / egret | file | `parse_file` / `convert_file` |
| GridFM (gridfm-datakit Parquet) | in | `read_gridfm` / `read_gridfm_scenarios` |
| OpenDSS / PowerModelsDistribution / IEEE BMOPF (distribution) | both | `parse_file(DistNetwork, …)` / `to_format` / `convert_file(DistNetwork, …)` |

The `parse_file` / `to_*` naming is shared across Rust, Python, Julia, and the
C ABI; the cross language table is in [docs/languages.md](docs/languages.md).

## Develop

With a sibling `powerio` checkout, build the C ABI and `using PowerIO` finds it:

```
# in the sibling powerio checkout (arrow → to_arrow, gridfm → read_gridfm, dist → dist_*):
cargo build -p powerio-capi --release --features arrow,gridfm,dist
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
PowerIO.set_library!("/path/to/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`
```

Users never build Rust: released versions fetch the per-platform binary as a
lazy artifact. The pipeline is described in [docs/binary.md](docs/binary.md).

## Roadmap

0.2.1 tracks powerio v0.3.1 (C ABI 4, distribution ABI 1) and repins the binary
artifacts. 0.2.0 added the multiconductor distribution binding
(`parse_file(DistNetwork, …)` / `to_format` / `convert_file(DistNetwork, …)`)
over OpenDSS, PowerModelsDistribution, and IEEE BMOPF. The 0.1.x line tracked C ABI 3: 0.1.0
added the gridfm reader, 0.1.1 the PyPSA CSV writer and `reference_bus_indices`,
0.1.2 the `n_components` / `is_radial` accessors. Next: a fully typed immutable
`Network` mirroring the Rust model (today's view is JSON-backed), a Documenter
site, package extensions for the PowerModels and ExaPowerIO bridges, and
distribution through a registered `PowerIO_jll`.

## License

MIT.
