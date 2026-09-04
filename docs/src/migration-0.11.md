# Migrating from 0.10 to 0.11

PowerIO.jl 0.11 binds PowerIO 0.11 over C ABI 7. Element tables are properties
that return typed Julia structs, the operations follow the cross language
vocabulary (`parse`, `emit`, `serialize`, `deserialize`, `calc_*`, `to_*`,
`apply_updates!`), and everything the 0.10 binding read from a network's JSON
payload now comes from typed C views.

## Parsing and writing

| 0.10 | 0.11 |
|---|---|
| `parse_file(path; format)` | `parse(path; format)` |
| `parse_text(text; name, format)` | `parse(IOBuffer(text); name, format)` or `parse(codeunits(text); ...)` |
| `parse_file(BalancedNetwork, path)` | `parse(path).value` |
| `kind(m)` | dispatch on `PioModule{T}` or `typeof(m.value)` |
| `inspect(m)`, `source_format(m)` | `m.sources`, `m.history`, `m.producer` |
| `emit(m, format)` returning `text` | `emit(m, format)` returning an `EmitResult`; `result.text`, `result.artifacts` |
| `to_json(m)`, `from_json(PioModule, text)` | `serialize(m)`, `deserialize(bytes)` |
| `to_json(net)`, `from_json(text)` | removed: a network is written through its module |
| `emit(m, "pio-json", path)` | `serialize(m, path)` |
| `resolve_format`, `FormatInfo` | removed: format discovery is not part of the C ABI |

## Network access

| 0.10 | 0.11 |
|---|---|
| `buses(net)`, `branches(net)`, `generators(net)`, `loads(net)`, `shunts(net)`, `storage(net)`, `hvdc(net)`, `switches(net)` | `net.buses`, `net.branches`, `net.generators`, `net.loads`, `net.shunts`, `net.storage`, `net.hvdc`, `net.switches` |
| `lines(net)`, `linecodes(net)`, `transformers(net)`, `ibrs(net)`, `control_profiles(net)`, `capacitors(net)`, `voltage_sources(net)`, `untyped(net)` | `net.lines`, `net.linecodes`, `net.transformers`, `net.ibrs`, `net.control_profiles`, `net.capacitors`, `net.voltage_sources`, `net.untyped` |
| `n_buses(net)`, `n_branches(net)`, `n_generators(net)`, `n_switches(net)` | `length(net.buses)`, `length(net.branches)`, ... |
| `base_mva(net)`, `base_frequency(net)`, `network_name(net)` | `net.base_mva`, `net.base_frequency`, `net.name` |
| `net.data.buses[1].vm` (a `JSON3.Object`) | `net.buses[1].vm_pu` (a `Bus`) |
| `reference_bus_id(net)`, `reference_bus_positions(net)` | `reference_bus_ids(net)` |
| `n_islands(net)`, `is_radial(net)` | removed: not part of the C ABI |
| `to_bus_type_code(kind)` | `bus.bus_type` is `"PQ"`, `"PV"`, `"REF"`, or `"ISOLATED"` |
| `to_normalized(net)` | removed: not part of the C ABI |
| `to_arrow`, `ArrowTable`, `arrow_catalog` | removed: ABI 7 has no Arrow export; use the element collections or `to_dense` |
| `to_dense(net)` | kept, assembled from the element collections; no `n_components` or `is_radial` fields |

Element struct fields use the C view names: `vm_pu` for `vm`, `va_degrees` for
`va`, `resistance_pu` for `r`, `reactance_pu` for `x`,
`total_charging_susceptance_pu` for `b`, `active_power_mw` for `pg`,
`from_bus_id` for `from`, `tap_ratio` for `tap`, `phase_shift_degrees` for
`shift`.

## Collections and calculations

| 0.10 | 0.11 |
|---|---|
| `list_states(m)`, `export_state(m; time=i)` | `series[i]` on a `TimeSeries`, `scenarios[id]` on a `ScenarioSet` |
| `to_balanced(m)`, `to_balanced_report(m)` | removed: not part of the C ABI |
| `calc_branch_susceptance_matrix` | `calc_branch_flow_matrix` |
| `calc_phase_shift_injection` | `calc_branch_phase_shift_injection` and `calc_bus_phase_shift_injection` |
| `calc_admittance_matrix`, `calc_bprime_matrix`, `calc_bdoubleprime_matrix` | kept; assembled in Julia from the element tables |
| `history(m)`, `module_sources(m)` | `m.history`, `m.sources` |

## Feature probes

| 0.10 | 0.11 |
|---|---|
| `features()`, `has_feature`, `build_info`, `schema_versions` | removed: ABI 7 declares one fixed symbol table |
| `arrow_available`, `matrix_available`, `gridfm_available`, `dist_available`, `prob_available` | removed; a build without `gridfm` reports a coded parse error |
| `abi_version() == 6` | `abi_version() == 7` |

## New in 0.11

- `apply_updates!` with typed updates ([Updates](updates.md)).
- `to_dc_pf_instance` and the other five constructions.
- `solution[quantity]`, `solution.instance`, `solution.termination`.
- `m.producer`, `m.sources`, `m.history` as typed records.
- `net.detailed_connectivity` counts for node breaker sources.
