# Migrating from 0.9

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

## The parse result is now a module

`parse_file` returns a [`PioModule`](@ref) instead of a bare network. `m.value` is
the typed value: a live `BalancedNetwork` or `MulticonductorNetwork` handle for
a transmission or distribution case, or one of the calculation, series, and
scenario families described in [Modules](modules.md) — twenty value kinds in
total, plus `UnknownValue` for a kind a newer library adds later.

```julia
# 0.9
net = parse_file("case14.m")
net.buses

# 0.10
m = parse_file("case14.m")
buses(m)
m.value.buses             # explicit value access also remains available
m.diagnostics             # field-like module findings
```

Network accessors, normalization, matrices, graphs, PowerModels and ExaModels
bridges, Arrow and dense extraction, and format conversion accept the module
directly. The corresponding `m.value` methods remain available. `to_json(m)`
writes the stored module; `to_json(m.value)` writes only the network model.

## Additive names in 0.10 patch releases

The descriptive Julia names below are aliases or forwarding methods. Existing
0.10 code keeps working without deprecation warnings.

| Preferred | Existing compatibility name or form |
|---|---|
| `parse_file(path)`, `parse_file(io; name, format)` | `parse_bytes` for memory input |
| `parse_file(source; format)` returning `PioModule` | `parse_file(T, source; from)` returning the network value |
| `emit(m, format)`, `emit(m, format, destination)` | `to_format`, `write_report_str`, `write_str`, `write_file` |
| `PowerIOError` | `PowerIOCError` |
| `to_balanced`, `to_balanced_report` | `lower_to_balanced`, `lowering_readiness` |
| `n_generators`, `n_islands` | `n_gens`, `n_components` |
| `reference_bus_positions` | `reference_bus_indices .+ 1` |
| `module_sources` | `sources(m::PioModule)` |
| `voltage_sources` | `sources(net::MulticonductorNetwork)` |
| `calc_incidence_matrix(m::PioModule)` | raw `incidence_matrix(::DcData)`; the released network and path `calc_incidence_matrix` overloads keep their 0.10 orientation until 1.0 |
| `calc_bus_susceptance_matrix`, `calc_branch_susceptance_matrix` | raw `susceptance_laplacian`, `flow_matrix` |
| `calc_phase_shift_injection`, `calc_branch_flow_dc` | raw `shift_injection`, `branch_flow` |
| `branch_ids`, `from_bus_positions`, `to_bus_positions` | `row_ids`, zero based `from_indices` / `to_indices` |

Balanced network and balanced operating point time series modules support
Julia integer indexing and iteration; scenario set modules support string keys
and indexing. Multiconductor operating point series expose their inventory but
not collection indexing because they have no lossless static materialization.

## emit uses one argument order

`emit(m, format)` returns text and writer findings. Add a destination as the
third argument to write a file or directory. An unchanged module emitted to
its source format reproduces the source bytes exactly.

```julia
m = parse_file("case14.m")
text, findings = emit(m, "matpower")
emit(m, "matpower", "copy.m")            # byte exact echo
emit(m, "psse", "copy.raw")              # cross format write
```

## Planned 1.0 export cleanup

PowerIO 0.10 keeps every released spelling callable and emits no deprecation
warnings. The final 1.0 export cleanup is limited to names that now have a
clear canonical replacement:

- `parse_bytes` leaves the ordinary export set; wrap bytes in `IOBuffer` and
  use `parse_file(io; name, format)`.
- The type marker `parse_file(T, source; from)` methods leave; dispatch on the
  `PioModule` returned by `parse_file(source; format)` and use `m.value` when a
  bare network is required.
- `DcData`, `dc_data`, `BorrowedVector`, and the raw span and mapping helpers
  leave the ordinary export set. The compatibility names `shift_injection`,
  `susceptance_laplacian`, `flow_matrix`, `bus_injection`, and `branch_flow`
  leave with them. Use `calc_incidence_matrix(m)`,
  `calc_bus_susceptance_matrix(m)`, `calc_branch_susceptance_matrix(m)`,
  `calc_phase_shift_injection(m)`, and `calc_branch_flow_dc(m, va)` on the
  module.
- The released `calc_incidence_matrix(::BalancedNetwork)` and path overloads
  return a bus by branch `BusMappedMatrix`. The module overload already returns
  the PowerModels branch by bus matrix. The final 1.0 break reconciles the old
  overloads to the module orientation.

These are export changes, not C ABI changes.

## Removed 0.9 entry points

| Removed | Replacement |
|---|---|
| `Network`, `NetworkHandle`, `DistNetwork`, `dist_graph` | `parse_file` returning `PioModule{BalancedNetwork}` or `PioModule{MulticonductorNetwork}`; `PowerIO.to_graph` |
| `NetworkPackage`, `CompilerPackage`, `to_package`, `from_package`, `read_package`, `write_package` | `PioModule`; `parse_file` reads a stored `.pio.json` document like any other source, and `to_json(m)` writes it |
| `ScopfInstance`, `parse_scopf`, `parse_goc3_json`, `goc3_scopf_data` | the `AcScucInstance` module kind, read through `parse_file` and the module surface |
| `OperatingPointSeries`, `TimeAxis`, `ElementUpdate`, `operating_point_series`, `materialize_operating_point_series` | `TimeSeries{OperatingPoint{T}}` modules; `state_inventory` and `select_state` |
| `as_network`, `as_dist_network` | `m.value` |
| `to_normalized_with_options` | keyword arguments on `to_normalized` |
| `parse_str` and its type marker form | `parse_file(IOBuffer(text); name, format)` |
| `dist_abi_version`, `dist_capabilities`, `PIO_DIST_ABI_VERSION` | the single ABI handshake below; `features()` and `build_info()` for what the library carries |

## One ABI handshake

At first use the binding checks `pio_abi_version` against the C ABI version it targets (6 in 0.10) and refuses a stale or mismatched library with an error stating both versions. Distribution entry points are covered by the same handshake; 0.9's separate `pio_dist_abi_version` check is gone along with the C symbol itself.

See the full [CHANGELOG](https://github.com/eigenergy/PowerIO.jl/blob/main/CHANGELOG.md) entry for 0.10.0 for the complete list of changes.

## 0.10 compatibility API reference

```@docs
parse_bytes
write_file
write_str
write_report_str
write_json
to_format(::PioModule, ::AbstractString)
lowering_readiness
PowerIOCError
DcData
dc_data
BorrowedVector
PowerIO.n_rows
PowerIO.n_branches(::DcData)
PowerIO.n_buses(::DcData)
PowerIO.from_bus_positions
PowerIO.to_bus_positions
PowerIO.from_indices
PowerIO.to_indices
PowerIO.susceptance
PowerIO.shift
PowerIO.shift_injection
PowerIO.branch_ids
PowerIO.row_ids
PowerIO.bus_ids
PowerIO.omitted
PowerIO.formula
PowerIO.incidence_matrix(::DcData)
susceptance_laplacian
flow_matrix
PowerIO.bus_injection(::DcData, ::AbstractVector{<:Real})
PowerIO.branch_flow(::DcData, ::AbstractVector{<:Real})
```
