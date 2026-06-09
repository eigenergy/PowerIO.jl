# PowerIO.jl

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/assets/powerio-logo.png"
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

> **Status: v0.0.1 release candidate.** Not yet registered. What remains: tag the
> powerio release (its CI attaches the per-platform `libpowerio_capi` tarballs),
> run `gen/update_artifacts.jl <tag>` to fill `Artifacts.toml`, register. After
> that `Pkg.add("PowerIO")` needs no Rust toolchain; the binary downloads lazily
> on first use. See [docs/binary.md](docs/binary.md).

## Install

```julia
pkg> add PowerIO                  # after registration in General
pkg> add https://github.com/eigenergy/PowerIO.jl   # until then
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
d.reference_bus, d.n_components, d.is_radial
```

`to_arrow` lends one table zero copy over the Arrow C Data Interface (needs the
library built with `--features arrow`; `arrow_available()` reports it). The
columns are a Tables.jl-shaped NamedTuple, so they flow into `Arrow.write`,
`DataFrame`, etc. Keep the returned `ArrowTable` alive while reading its columns:

```julia
t = to_arrow(net, :branch)        # :bus, :branch, :gen, :load, :shunt
t.from, t.x, t.tap                # zero-copy column views
```

At first use the binding checks `pio_abi_version` against the version it targets
and refuses a stale or mismatched library with a directed error.

## Interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` / `parse_ac_power_data` feeding `build_polar_opf` / `build_rect_opf` / `build_dcopf` |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| MATPOWER / PSS/E / PowerWorld / PowerModels JSON / egret | file | `parse_file` / `convert_file` |

The same `parse_file` / `to_*` verb taxonomy holds across Rust, Python, Julia,
and the C ABI; the cross-language table is in
[docs/languages.md](docs/languages.md).

## Develop

With a sibling `powerio` checkout, build the C ABI and `using PowerIO` finds it:

```
# in the sibling powerio checkout (--features arrow also enables to_arrow):
cargo build -p powerio-capi --release --features arrow
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
PowerIO.set_library!("/path/to/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`
```

Users never build Rust: released versions fetch the per-platform binary as a
lazy artifact. The pipeline is described in [docs/binary.md](docs/binary.md).

## Roadmap

Registration in General is the v0.0.1 milestone. After that: a fully typed
immutable `Network` mirroring the Rust model (today's view is JSON-backed), a
Documenter site, package extensions for the PowerModels and ExaPowerIO bridges,
and the Yggdrasil `PowerIO_jll` swap.

## License

MIT.
