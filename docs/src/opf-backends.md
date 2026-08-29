# OPF instance backends

An OPF instance is solver input derived from a parsed network. It carries
topology, bounds, costs, reserves, and time data without choosing a variable
stacking or solver. A consumer builds a model or program from that instance.

## Current state

| Instance | Class | Rust implementation | PowerIO.jl surface |
|---|---|---|---|
| `DcOpfInstance` | DC OPF | `powerio-prob` | `dc_data` and the matrix assemblies |
| `AcOpfInstance` | AC OPF | `powerio-prob` | dense network tables |
| `AcScucInstance` | AC SCUC | `powerio-prob` | the stored module (kind `ac_scuc_instance`) |

A source that defines a calculation parses to that calculation's typed value:
DOE GO Challenge 3 JSON compiles to the `AcScucInstance` module kind through
[`parse_file`](@ref). The 0.9 SCOPF projection (`pio_scopf_*`, `ScopfInstance`,
`parse_scopf`, `goc3_scopf_data`) is retired; consumers read the typed
instance through the module surface or build from the matrix and dense table
surfaces.

## Instance versus model

PowerIO emits instances. ExaModelsPower.jl and other consumers turn them into
models or programs and later produce solutions. Keep those layers explicit in
type names: an instance is input data, while a consumer owns its model and
solution types.
