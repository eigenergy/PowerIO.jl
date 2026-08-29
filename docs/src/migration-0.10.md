# Migrating from 0.9

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

## The parse result is now a module

`parse_file` and `parse_bytes` return a [`PioModule`](@ref) instead of a bare network. `m.value` is the typed value: a live `BalancedNetwork` or `MulticonductorNetwork` handle for a transmission or distribution case, or one of the calculation, series, and scenario families described in [Modules](modules.md) — twenty value kinds in total, plus `UnknownValue` for a kind a newer library adds later.

```julia
# 0.9
net = parse_file("case14.m")
net.buses

# 0.10
m = parse_file("case14.m")
net = m.value
net.buses
```

Matrix and conversion functions (`calc_admittance_matrix`, `to_format`, `to_json`, and the rest) still take the unwrapped value, `m.value`, and dispatch on its type exactly as before. Inspection (`inspect`, `kind`, `diagnostics`), state selection (`state_inventory`, `select_state`), and writing (`write_file`, `write_str`, `write_json`) take the module itself.

## write_file echoes the source by default

`write_file(m, path)` with no `format` keyword writes the module's own source format, and for an unchanged module that reproduces the source bytes exactly. Pass `format` to target a different format, or when the module has no recorded source (built in memory).

```julia
m = parse_file("case14.m")
write_file(m, "copy.m")             # byte exact echo, same format as the source
write_file(m, "copy.raw"; format="psse")  # cross format write
```

## Removed 0.9 entry points

| Removed | Replacement |
|---|---|
| `Network`, `NetworkHandle`, `DistNetwork`, `dist_graph` | `parse_file` returning `PioModule{BalancedNetwork}` or `PioModule{MulticonductorNetwork}`; `PowerIO.to_graph` |
| `NetworkPackage`, `CompilerPackage`, `to_package`, `from_package`, `read_package`, `write_package` | `PioModule`; `parse_file` / `parse_bytes` read a stored `.pio.json` document the same way as any other source, and `write_json` writes it |
| `ScopfInstance`, `parse_scopf`, `parse_goc3_json`, `goc3_scopf_data` | the `AcScucInstance` module kind, read through `parse_file` and the module surface |
| `OperatingPointSeries`, `TimeAxis`, `ElementUpdate`, `operating_point_series`, `materialize_operating_point_series` | `TimeSeries{OperatingPoint{T}}` modules; `state_inventory` and `select_state` |
| `as_network`, `as_dist_network` | `m.value` |
| `to_normalized_with_options` | keyword arguments on `to_normalized` |
| the type marker forms of `parse_file` and `parse_str`, the bare `PowerIO.parse` dispatcher | `parse_file` / `parse_bytes` (format and value kind detected together); pass `format` to pin an ambiguous source |
| `dist_abi_version`, `dist_capabilities`, `PIO_DIST_ABI_VERSION` | the single ABI handshake below; `features()` and `build_info()` for what the library carries |

## One ABI handshake

At first use the binding checks `pio_abi_version` against the C ABI version it targets (6 in 0.10) and refuses a stale or mismatched library with an error stating both versions. Distribution entry points are covered by the same handshake; 0.9's separate `pio_dist_abi_version` check is gone along with the C symbol itself.

See the full [CHANGELOG](https://github.com/eigenergy/PowerIO.jl/blob/main/CHANGELOG.md) entry for 0.10.0 for the complete list of changes.
