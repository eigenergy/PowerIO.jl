# PowerIO.jl

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/src/assets/powerio-logo.svg"
    alt="PowerIO logo"
    width="120"
  >
</p>

PowerIO 0.10 is the public beta of the 1.0 API. It reads power system data
through the PowerIO Rust library and exposes typed values through Julia.

```julia
using PowerIO

module_ = parse_file("case14.m")       # PioModule{BalancedNetwork}
n_buses(module_)                       # 14
module_.diagnostics                    # Vector{Diagnostic}
emit(module_, "matpower", "copy.m")  # byte exact same format write
```

[Read the documentation](https://eigenergy.github.io/PowerIO.jl).

## Install

```julia
pkg> add PowerIO
```

Released versions download the matching `powerio-capi` library as a Julia
artifact. See [Binary distribution](docs/src/binary.md) when developing against
a local Rust build.

## Values and formats

`parse_file` detects the value kind from a path or stream. A
`PioModule{T}` contains one typed value plus its sources, diagnostics, source
map, and history. The value can be a network, calculation instance, solution,
time series, or scenario set.

Balanced transmission formats include MATPOWER, PSS/E, PowerWorld AUX, PSLF
EPC, PowerModels JSON, Egret JSON, pandapower JSON, PyPSA CSV, and Surge JSON.
OpenDSS, PowerModelsDistribution engineering JSON, and IEEE BMOPF JSON use the
multiconductor distribution model. DOE GO Challenge 3, BMOPF, and DeepMind
OPFData inputs produce calculation instances or solutions. GridFM datasets and
supported PyPSA or Egret profiles can produce scenario sets or time series.

```julia
feeder_module = parse_file("feeder.dss")
lines(feeder_module)
transformers(feeder_module)

scuc = parse_file("scenario_002.json")   # PioModule{AcScucInstance}
```

Pass `format` only when the file name cannot identify the source, such as JSON
shared by several formats:

```julia
egret = parse_file("grid.json"; format="egret")
```

## Networks and matrices

The exported accessors work without a `PowerIO.` prefix after `using PowerIO`.

```julia
case = parse_file("case14.m")

buses(case)
branches(case)
generators(case)
base_mva(case)
reference_bus_positions(case)

ybus = calc_admittance_matrix(case)      # BusMappedMatrix{ComplexF64}
Y = ybus.matrix                          # SparseMatrixCSC
A = calc_incidence_matrix(case)          # branches by buses
B = calc_bus_susceptance_matrix(case)    # buses by buses
Bf = calc_branch_susceptance_matrix(case) # branches by buses
p_shift = calc_phase_shift_injection(case)
```

`BusMappedMatrix` keeps the sparse matrix together with `idx_to_bus` and
`bus_to_idx`. The canonical DC calculations use `calc_*` verbs and follow the
PowerModels branch by bus incidence convention.

## Writing and conversion

An unchanged module writes its original format byte for byte. Cross format
conversion reports fields the destination cannot represent as diagnostics.

```julia
module_ = parse_file("case14.m")
emit(module_, "matpower", "copy.m")

text, findings = emit(module_, "psse")
pm_data = to_powermodels(module_)
ref = build_powermodels_ref(pm_data)
```

`to_json(module_)` writes the versioned `.pio.json` module document and
`from_json(PioModule, text)` reads it. `to_json(module_.value)` and
`from_json(BalancedNetwork, text)` read and write only the balanced network
model JSON.

## Package structure

PowerIO.jl calls the PowerIO C ABI. ABI 6 carries owned module, network,
diagnostic, matrix, and problem data handles. The Julia package checks the ABI
before its first call and reports the required and loaded versions if they do
not match.

The user guides cover [modules](docs/src/modules.md),
[transmission networks](docs/src/transmission.md),
[distribution networks](docs/src/distribution.md),
[matrices](docs/src/matrices.md), [OPF data](docs/src/opf-backends.md), and
[ecosystem interop](docs/src/interop.md). Migration and implementation details
are grouped under Developer Guides in the published documentation.

## Development

Build the sibling Rust checkout with the release features:

```sh
cargo build -p powerio-capi --release --features arrow,matrix,gridfm,dist,prob
```

For another layout, select the library from Julia:

```julia
using PowerIO

set_library!("/path/to/libpowerio_capi.dylib")
set_library!("/path/to/libpowerio_capi.dylib"; persist=true)
clear_library!(persist=true)
```

## License

MIT.
