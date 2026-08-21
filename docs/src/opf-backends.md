# OPF instance backends

An OPF instance is solver input derived from a parsed network. It carries
topology, bounds, costs, reserves, and time data without choosing a variable
stacking or solver. A consumer builds a model or program from that instance.

## Current state

| Instance | Class | Rust implementation | PowerIO.jl surface |
|---|---|---|---|
| `DcOpfInstance` | DC OPF | `powerio-prob` | matrices and dense network tables |
| `AcOpfInstance` | AC OPF | `powerio-prob` | dense network tables |
| `ScopfInstance` | SCOPF | `powerio-prob` | [`goc3_scopf_data`](@ref) |

The native SCOPF path has one projection. `pio_scopf_parse_str` builds the Rust
`ScopfInstance`, `pio_scopf_to_json` serializes the language neutral
`powerio.scopf` document, and `goc3_scopf_data` types the same rows as Julia
NamedTuples. The JSON indices are 1-based. Every ordinal comes from source
document order; no uid spelling participates in indexing.

[`ScopfInstance`](@ref) carries buses, shunts, AC and DC branches, transformer
control sets, producers, consumers, zonal reserves, contingency survivor sets,
energy windows, price blocks, violation costs, interval durations, and the
source device class layout. `j_dev` is the position within a producer or
consumer class. `j_sdd` is the position in the canonical producer block
followed by the consumer block. Both remain valid when the source device rows
interleave.

The C surface exports SCOPF as an owned handle plus one versioned document. It
does not expose the DC or AC instances in v0.9.0. Consumers that need those
instances use Rust directly or build from the matrix and dense table surfaces.

## Instance versus model

PowerIO emits instances. ExaModelsPower.jl and other consumers turn them into
models or programs and later produce solutions. Keep those layers explicit in
type names: `ScopfInstance` is input data, while a consumer owns its model and
solution types.
