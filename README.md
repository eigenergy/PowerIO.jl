# PowerIO.jl

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/src/assets/powerio-logo.svg"
    alt="PowerIO logo"
    width="120"
  >
</p>

Julia bindings for [PowerIO](https://github.com/eigenergy/powerio), which reads
power system case files into a typed `BalancedNetwork`, writes them back, and converts
between formats. The Rust core does the parsing and the byte exact write, so a
case reads identically in Julia, Python, C/C++, and Rust.

**Documentation: [eigenergy.github.io/PowerIO.jl](https://eigenergy.github.io/PowerIO.jl)**

Supported transmission formats (each reads and writes, so any pair converts):

- [MATPOWER](https://matpower.org/) `.m`
- [PSS/E](https://www.siemens.com/global/en/products/energy/grid-software/planning/pss-software/pss-e.html) `.raw` revision 33
- [PowerWorld](https://www.powerworld.com/WebHelp/Content/MainDocumentation_HTML/Case_Formats.htm) `.aux`
- [PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl) network data JSON
- [egret](https://pypi.org/project/gridx-egret/) `ModelData` JSON

A same-format round trip is byte exact; cross-format conversion reports fields
the target cannot represent as warnings. Multiconductor distribution cases
(OpenDSS, PowerModelsDistribution JSON, IEEE BMOPF JSON) parse into the
separate `MulticonductorNetwork` model through the same verbs; see the
[distribution guide](https://eigenergy.github.io/PowerIO.jl/distribution/).

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/src/assets/powerio-hero.png"
    alt="PowerIO format and matrix flow"
    width="720"
  >
</p>

## Install

```julia
pkg> add PowerIO
```

Released versions fetch the per-platform `powerio-capi` binary as a lazy
artifact; users never build Rust. Working on the binding itself needs a local
build; see Develop below.

## Use

```julia
using PowerIO

net = parse_file("case14.m")
net isa BalancedNetwork
PowerIO.n_buses(net), PowerIO.n_gens(net), PowerIO.base_mva(net)
PowerIO.source_format(net)        # "Matpower"
PowerIO.reference_bus_id(net)     # the slack bus id (or nothing)

text, warnings = convert_file("case14.m", "psse")

# egret and PowerModels both use .json; pass `from` to disambiguate:
egret = parse_file("grid.json"; from="egret")
```

The main transforms off a parsed network:

```julia
to_normalized(net)                 # per unit, radians, filtered copy
to_dense(net)                      # dense typed arrays for matrix assembly
to_arrow(net, :branch)             # one table over the Arrow C Data Interface
to_matpower(net)                   # byte exact when the input was MATPOWER
to_format(net, "powermodels-json") # (text, warnings)
to_powermodels(net)                # PowerModels.jl network data Dict
to_powerdata(net)                  # ExaPowerIO PowerData NamedTuple
to_package(net)                    # .pio.json compiler package
```

Distribution cases share the verbs, routed by format:

```julia
dn = parse_file("feeder.dss")        # ::MulticonductorNetwork, element tables + handle
PowerIO.buses(dn), PowerIO.lines(dn), PowerIO.transformers(dn)
text, warnings = to_format(dn, "pmd")
```

The [transmission](https://eigenergy.github.io/PowerIO.jl/transmission/),
[distribution](https://eigenergy.github.io/PowerIO.jl/distribution/), and
[interop](https://eigenergy.github.io/PowerIO.jl/interop/) guides cover the
full surface: accessors, Arrow export, `.pio.json` packages, the gridfm
reader, and GO Challenge 3 helpers.

At first use the binding checks `pio_abi_version` against the core ABI version
it targets and refuses a stale or mismatched library with an error stating both
versions. Distribution entry points also check `pio_dist_abi_version`.

## Interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` / `parse_ac_power_data` feeding `build_polar_opf` / `build_rect_opf` / `build_dcopf` |
| powerio-pkg `.pio.json` | both models | `to_package` / `from_package` / `read_package` / `write_package` |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| MATPOWER / PSS/E / PowerWorld / PowerModels JSON / egret | file | `parse_file` / `convert_file` |
| GridFM (gridfm-datakit Parquet) | in | `read_gridfm` / `read_gridfm_scenarios` |
| OpenDSS / PowerModelsDistribution / IEEE BMOPF (distribution) | both | format-routed `parse_file` / `to_format` / `convert_file` |

The `parse_file` / `to_*` naming is shared across Rust, Python, Julia, and the
C ABI; the cross language table is in
[docs/src/languages.md](docs/src/languages.md).

## Develop

With a sibling `powerio` checkout, build the C ABI and `using PowerIO` finds it:

```
# in the sibling powerio checkout:
cargo build -p powerio-capi --release --features arrow,gridfm,dist,pkg
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
PowerIO.set_library!("/path/to/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`
```

The artifact pipeline behind released versions is described in
[docs/src/binary.md](docs/src/binary.md).

## Roadmap

0.6.0 tracks powerio v0.6.0 in lockstep (C ABI 4, distribution ABI 1). Next: a fully typed immutable `BalancedNetwork` mirroring
the Rust model (today's view is JSON-backed), package extensions for the
PowerModels and ExaPowerIO bridges, and distribution through a registered
`PowerIO_jll`. Version history is in [CHANGELOG.md](CHANGELOG.md).

## License

MIT.
