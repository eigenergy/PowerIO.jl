# Migrating from 0.9 and 0.10

PowerIO.jl 1.0 completes the API break announced with the 0.10 beta. The 1.0
surface uses `parse_file` for filesystem input, `parse_text` for in-memory
text, `to_*` for in-memory conversions, `calc_*` for calculations, and `emit`
for external output.

## Parsing returns a module

`parse_file` and `parse_text` return a [`PioModule`](@ref). Its `value` field
holds the typed value and its `diagnostics` field holds structured findings.

```julia
case = parse_file("case14.m")
case.value
case.diagnostics

inline = parse_text(matpower_text; name="case14.m", format="matpower")
```

Use `parse_file(path; format)` for a file or directory. Use
`parse_text(text; name, format)` only for text already in memory. In-memory
text cannot resolve included files; a non-`nothing` `include_root` raises an
`ArgumentError`. Put an include based input on disk and call `parse_file`.

The public `parse_bytes`, `parse_file(::IO)`, positional format, and type
marker overloads were removed. Binary formats such as PowerWorld PWB remain
filesystem inputs.

Network accessors, normalization, matrices, graphs, PowerModels and
ExaModelsPower bridges, Arrow and dense extraction, and emission accept the
module directly. Take `case.value` only when a bare value is required.
`to_json(case)` returns a stored module document; `to_json(case.value)`
returns the network model JSON.

An existing live network can be wrapped without serialization:

```julia
net = from_json(BalancedNetwork, model_json)
case = PioModule(net)
```

`PioModule(value)` accepts `BalancedNetwork` and `MulticonductorNetwork` and
keeps retained source and common records attached to the live value.

## Output uses emit

`emit(case, format)` returns an `EmitResult` with `text` and `diagnostics`
fields. Add a destination as the third argument to emit a file or directory;
the same result type is returned with `text === nothing`.

```julia
case = parse_file("case14.m")
result = emit(case, "matpower")
result.text
result.diagnostics
emit(case, "matpower", "copy.m")
emit(case, "psse", "copy.raw")
```

An unchanged module emitted to its source format reproduces the source bytes.

## Final 1.0 replacements

| Removed 0.10 surface | 1.0 surface |
|---|---|
| `parse_bytes`, `parse_file(io, format; name)`, `parse_file(T, source; from)` | `parse_text(text; name, format)` or `parse_file(path; format)` |
| `diagnostics(m)`, `warnings(net)` | `m.diagnostics` |
| `convert_file`, `convert_str` | parse, then `emit` |
| `to_format`, `to_matpower`, `write_file`, `write_str`, `write_report_str` | `emit(m, format[, destination])` |
| `write_json(m)` | `to_json(m)` |
| `write_pypsa_csv_folder(net, dir)` | `emit(PioModule(net), "pypsa-csv", dir)` |
| `read_gridfm`, `read_gridfm_scenarios` | `parse_file(dir; format="gridfm")`, then scenario set indexing |
| `state_inventory` | `list_states` |
| `select_state` | `export_state` |
| `PowerIOCError` | `PowerIOError` |
| `lower_to_balanced`, `lowering_readiness` | `to_balanced`, `to_balanced_report` |
| `n_gens`, `n_components` | `n_generators`, `n_islands` |
| `reference_bus_indices` | `reference_bus_positions` |
| `sources(m::PioModule)` | `module_sources` |
| `sources(net::MulticonductorNetwork)` | `voltage_sources` |
| `release_c_data` | `close` |
| `bus_type_code` | `to_bus_type_code` |
| `parse_ac_power_data` | `to_ac_power_data` |
| `calc_susceptance_matrix` | `calc_bprime_matrix` for FDPF `B'`; `calc_bus_susceptance_matrix` for the canonical DC bus matrix |
| `AdmittanceMatrix` | `BusMappedMatrix` |

The public low level DC aggregate and its borrowed views were also removed:
`DcData`, `dc_data`, `BorrowedVector`, `n_rows`, `row_ids`, `branch_ids`,
`bus_ids`, `from_indices`, `to_indices`, `from_bus_positions`,
`to_bus_positions`, `susceptance`, `shift`, `shift_injection`, `omitted`,
`formula`, `incidence_matrix`, `susceptance_laplacian`, `flow_matrix`,
`bus_injection`, and `branch_flow`. There is no renamed aggregate. Call the
named calculations directly on a balanced network module:

```julia
A = calc_incidence_matrix(case)
B = calc_bus_susceptance_matrix(case)
Bf = calc_branch_susceptance_matrix(case)
p_shift = calc_phase_shift_injection(case)
p_bus = calc_bus_injection_dc(case, voltage_angles)
p_branch = calc_branch_flow_dc(case, voltage_angles)
```

`calc_incidence_matrix(::BalancedNetwork)` and the path overload now match the
module overload and return the PowerModels branch by bus matrix. The 0.10 bus
by branch `BusMappedMatrix` behavior was removed.

These are Julia source changes. The private binding still uses the stable ABI
6 acquisition and DC array functions needed to implement the direct methods.

## Removed 0.9 entry points

| Removed | Replacement |
|---|---|
| `Network`, `NetworkHandle`, `DistNetwork`, `dist_graph` | `parse_file` returning `PioModule{BalancedNetwork}` or `PioModule{MulticonductorNetwork}`; `to_graph` |
| `NetworkPackage`, `CompilerPackage`, `to_package`, `from_package`, `read_package`, `write_package` | `PioModule`; `parse_file` for stored `.pio.json`; `to_json(m)` for output |
| `ScopfInstance`, `parse_scopf`, `parse_goc3_json`, `goc3_scopf_data` | `AcScucInstance`, parsed through the module surface |
| `OperatingPointSeries`, `TimeAxis`, `ElementUpdate`, `operating_point_series`, `materialize_operating_point_series` | `TimeSeries{OperatingPoint{T}}`; `list_states` and `export_state` |
| `as_network`, `as_dist_network` | `m.value` |
| `to_normalized_with_options` | keyword arguments on `to_normalized` |
| `parse_str` and its type marker form | `parse_text(text; name, format)` |
| `dist_abi_version`, `dist_capabilities`, `PIO_DIST_ABI_VERSION` | the single ABI handshake; `features()` and `build_info()` |

## One ABI handshake

At first use the binding checks `pio_abi_version` against ABI 6 and refuses a
stale or mismatched library before another C call runs. Distribution entry
points use the same handshake.
