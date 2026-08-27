# OPF instance backends

An OPF instance is solver input derived from a parsed network. It carries
topology, bounds, costs, reserves, and time data without choosing a variable
stacking or solver. A consumer builds a model or program from that instance.

## Current state

| Instance | Class | Rust implementation | PowerIO.jl surface |
|---|---|---|---|
| `DcOpfInstance` | DC OPF | `powerio-prob` | matrices and dense network tables |
| `AcOpfInstance` | AC OPF | `powerio-prob` | dense network tables |
| `AcScucInstance` | SCUC | `powerio-prob` | Rust only |

The 0.9 SCOPF binding (`parse_scopf`, `goc3_scopf_data`, `ScopfInstance`
NamedTuples) is gone with the ABI 5 surface; the Rust `powerio-prob` crate owns
the problem instances, and the C ABI exports the DC branch data the matrix
assembly consumes ([`dc_data`](@ref)). Consumers that need a full instance use
Rust directly.

## Instance versus model

PowerIO emits instances. ExaModelsPower.jl and other consumers turn them into
models or programs and later produce solutions. Keep those layers explicit in
type names: `ScopfInstance` is input data, while a consumer owns its model and
solution types.
