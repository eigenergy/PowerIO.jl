# PowerIO.jl

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/src/assets/powerio-logo.svg"
    alt="PowerIO logo"
    width="120"
  >
</p>

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

Julia binding of [PowerIO](https://github.com/eigenergy/powerio), the power
system data compiler. One call parses any supported source into a typed
module; the Rust core reads it, writes it back byte exact, converts between
formats, and exposes the same values through Julia, Python, C/C++, and Rust.

```julia
using PowerIO
case = parse_file("case14.m")       # PioModule{BalancedNetwork}
n_buses(case.value)                 # 14
diagnostics(case)                   # the reader's findings, native records
write_file(case, "copy.m"; format="matpower")  # byte exact same format echo
```

**Documentation: [eigenergy.github.io/PowerIO.jl](https://eigenergy.github.io/PowerIO.jl)**

Supported transmission formats:

- [MATPOWER](https://matpower.org/) `.m`
- [PSS/E](https://www.siemens.com/global/en/products/energy/grid-software/planning/pss-software/pss-e.html) `.raw` revisions 33, 34, and 35
- [PowerWorld](https://www.powerworld.com/WebHelp/Content/MainDocumentation_HTML/Case_Formats.htm) `.aux`
- PSLF EPC
- [PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl) network data JSON
- [egret](https://pypi.org/project/gridx-egret/) `ModelData` JSON
- pandapower JSON
- PyPSA CSV folders
- Surge JSON

Supported distribution formats:

- OpenDSS `.dss`
- PowerModelsDistribution ENGINEERING JSON
- IEEE BMOPF JSON

The stored `.pio.json` document (`write_json`) carries any value kind between
PowerIO consumers with its sources, findings, and history. `to_json` /
`from_json` expose the balanced model's own JSON snapshot; files shared with
other tools stay in the format the tool reads.

Each classical exchange format reads and writes where the Rust core has a
writer, so any supported pair converts. A same format round trip is byte exact;
cross format conversion reports fields the target cannot represent as warnings.
Multiconductor distribution cases parse into the separate
`MulticonductorNetwork` model through the same verbs; see the
[distribution guide](https://eigenergy.github.io/PowerIO.jl/distribution/).
GridFM Parquet readback and GO Challenge 3 helpers round out the data import
API.

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

m = parse_file("case14.m")     # ::PioModule{BalancedNetwork}
net = m.value
PowerIO.buses(net)              # raw bus table
net.buses                       # property form; materializes the cached JSON payload
net.name, net.source_format     # summary backed metadata; leaves net.data unset
length(PowerIO.buses(net))      # bus count
PowerIO.n_buses(net)            # summary backed count
PowerIO.n_gens(net), PowerIO.base_mva(net)
PowerIO.source_format(net)        # "matpower"
PowerIO.reference_bus_id(net)     # the slack bus id (or nothing)

text, warnings = convert_file("case14.m", "psse")

# egret and PowerModels both use .json; pass `format` to disambiguate:
egret = parse_file("grid.json"; format="egret")
```

The main transforms off a parsed network:

```julia
to_normalized(net)                 # per unit, radians, filtered copy
to_normalized(net; clamp_angle_bounds=true)
to_dense(net)                      # dense typed arrays for matrix assembly
calc_admittance_matrix(net).matrix # Ybus as SparseMatrixCSC{ComplexF64}
calc_susceptance_matrix(net).matrix
calc_incidence_matrix(net)
calc_bprime_matrix(net).matrix     # Rust B' positive Laplacian
to_arrow(net, :branch)             # one table over the Arrow C Data Interface
to_arrow(net, :bprime)             # lower level matrix COO table
to_matpower(net)                   # byte exact when the input was MATPOWER
to_format(net, "powermodels-json") # (text, warnings)
to_powermodels(net)                # PowerModels.jl network data Dict
to_powerdata(net)                  # ExaPowerIO PowerData NamedTuple
features()                         # optional C ABI features
```

Distribution cases share the verbs, routed by format:

```julia
dn = parse_file("feeder.dss").value  # ::MulticonductorNetwork, live handle
PowerIO.buses(dn), PowerIO.lines(dn), PowerIO.transformers(dn)
dn.warnings
PowerIO.to_graph(dn)
text, warnings = to_format(dn, "pmd")
```

The [transmission](https://eigenergy.github.io/PowerIO.jl/transmission/),
[distribution](https://eigenergy.github.io/PowerIO.jl/distribution/), and
[interop](https://eigenergy.github.io/PowerIO.jl/interop/) guides cover the
full API: accessors, Arrow export, `.pio.json` modules, the gridfm
reader, and GO Challenge 3 helpers.

At first use the binding checks `pio_abi_version` against the core ABI version
it targets and refuses a stale or mismatched library with an error stating both
versions. Distribution entry points also check `pio_dist_abi_version`.

## Interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` |
| BMOPFTools.jl | both | PowerIO backed OpenDSS / BMOPF conversion |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` / `parse_ac_power_data` feeding `build_polar_opf` / `build_rect_opf` / `build_dcopf` |
| PowerGridPlanning.jl | out | `to_powermodels`, `build_ref`, and angle repair helpers |
| stored `.pio.json` module | both | `parse_file` / `write_json` / `m.value` |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| MATPOWER / PSS/E / PowerWorld / PSLF / PowerModels JSON / egret / pandapower / PyPSA / Surge | file | `parse_file` / `convert_file` |
| GridFM (gridfm-datakit Parquet) | in | `read_gridfm` / `read_gridfm_scenarios` |
| OpenDSS / PowerModelsDistribution / IEEE BMOPF (distribution) | both | format-routed `parse_file` / `to_format` / `convert_file` |

The `parse_file` / `to_*` naming is shared across Rust, Python, Julia, and the
C ABI; the cross language table is in
[docs/src/languages.md](docs/src/languages.md).

## Develop

With a sibling `powerio` checkout, build the C ABI and `using PowerIO` finds it
before the released artifact:

```
# in the sibling powerio checkout:
cargo build -p powerio-capi --release --features arrow,matrix,gridfm,dist,prob
```

For a non-sibling layout, point Julia at the library explicitly:

```julia
PowerIO.set_library!("/path/to/libpowerio_capi.dylib")

# Save the override in LocalPreferences.toml for this Julia environment:
PowerIO.set_library!("/path/to/libpowerio_capi.dylib"; persist=true)
PowerIO.clear_library!(persist=true)
```

The artifact pipeline behind released versions is described in
[docs/src/binary.md](docs/src/binary.md).

## Version line

Each PowerIO.jl release pins one powerio release. `Artifacts.toml` records
the exact pinned tag, and each CHANGELOG section names the C ABI pair it
keeps. The released artifacts enable the Arrow, matrix, GridFM, distribution,
and problem instance features. The Julia package stays thin around
the C ABI while owning stable Julia entry points for parsing, conversion,
modules, dense tables, Arrow tables, distribution networks, GridFM, and
ecosystem interop.
`PowerIO_jll` remains the later distribution cleanup. Version history is in
[CHANGELOG.md](CHANGELOG.md).

## License

MIT.
