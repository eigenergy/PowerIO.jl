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
network = module_.value
n_buses(network)                       # 14
diagnostics(module_)                   # Vector{Diagnostic}
write_file(module_, "copy.m")         # byte exact same format write
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

`parse_file` and `parse_bytes` detect the value kind from the source. A
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
feeder = feeder_module.value             # MulticonductorNetwork
lines(feeder)
transformers(feeder)

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
network = parse_file("case14.m").value

buses(network)
branches(network)
generators(network)
base_mva(network)
reference_bus_indices(network)

ybus = calc_admittance_matrix(network)   # BusMappedMatrix{ComplexF64}
Y = ybus.matrix                          # SparseMatrixCSC
A = calc_incidence_matrix(network).matrix
```

`BusMappedMatrix` keeps the sparse matrix together with `idx_to_bus` and
`bus_to_idx`. Incidence rows are buses and its columns are branches.

## Writing and conversion

An unchanged module writes its original format byte for byte. Cross format
conversion reports fields the destination cannot represent as diagnostics.

```julia
module_ = parse_file("case14.m")
write_file(module_, "copy.m")

text, findings = convert_file("case14.m", "psse")
pm_data = to_powermodels(module_.value)
ref = build_powermodels_ref(pm_data)
```

`write_json(module_)` writes the versioned `.pio.json` module document.
`to_json(network)` and `from_json(text)` read and write the balanced network
model JSON used inside PowerIO.

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
