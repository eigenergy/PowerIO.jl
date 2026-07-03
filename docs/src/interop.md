# Ecosystem interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | [`to_powermodels`](@ref) / [`from_powermodels`](@ref) |
| ExaModelsPower.jl / ExaPowerIO.jl | out | [`to_powerdata`](@ref) / [`parse_ac_power_data`](@ref) |
| powerio-pkg `.pio.json` | both | [`to_package`](@ref) / [`from_package`](@ref) / [`read_package`](@ref) / [`write_package`](@ref) |
| GridFM (gridfm-datakit Parquet) | in | [`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) |
| GO Challenge 3 JSON | in | [`parse_goc3_json`](@ref) |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| OpenDSS / PMD / IEEE BMOPF | both | format-routed `parse_file` / `to_format`; see [Distribution networks](distribution.md) |

## PowerModels.jl

[`to_powermodels`](@ref) converts a parsed network to a PowerModels network
data dictionary — the post-parse `Dict{String,Any}` shape PowerModels.jl
consumes. [`from_powermodels`](@ref) reads one back.

```julia
net = parse_file("case14.m")
data = to_powermodels(net)      # Dict{String,Any} with "bus", "branch", "gen", ...
net2 = from_powermodels(data)
```

## ExaModelsPower.jl

[`to_powerdata`](@ref) returns a NamedTuple in ExaPowerIO's `PowerData`
shape; [`parse_ac_power_data`](@ref) returns the NamedTuple-of-arrays shape
consumed by ExaModelsPower's `build_polar_opf`, `build_rect_opf`, and
`build_dcopf` — GPU-ready struct-of-arrays with per unit conversion applied.

```julia
pd = to_powerdata("case14.m")
ac = parse_ac_power_data("case14.m")
ac.bus, ac.gen, ac.branch, ac.arc, ac.ref_buses
```

## `.pio.json` network packages

`.pio.json` compiler packages wrap balanced and multiconductor networks with
validation and provenance, over the native `pio_package_*` C ABI surface
(needs the default `pkg` feature; [`package_available`](@ref) reports it).

```julia
pkg = to_package(net)                    # ::CompilerPackage, model_kind = :balanced
json = to_json(pkg)                      # the .pio.json envelope
net = from_package(json)                 # back to a live BalancedNetwork
write_package("case14.pio.json", pkg)
pkg = read_package("case14.pio.json")

package_validation(pkg).status           # "ok"
package_diagnostics(pkg)                 # structured diagnostics
validated = validate_package(pkg)
```

`to_package(net; include_solver_metadata=true)` records the compact
normalized solver table identity block used by `powerio-pkg`. Multiconductor
packages preflight and lower explicitly; see
[Distribution networks](distribution.md).

## GridFM

[`read_gridfm`](@ref) reads a gridfm-datakit Parquet dataset back into a
`BalancedNetwork` — the ML to classical return leg (needs `--features
gridfm`; [`gridfm_available`](@ref) reports it). The read is lossy but
complete enough for power flow; what the schema can't round trip comes back
in `warnings`.

```julia
r = read_gridfm("out/case14/raw")                # (; network, scenario, warnings)
to_matpower(r.network)                           # gridfm -> any classical format
reads = read_gridfm_scenarios("out/case14/raw")  # one result per scenario id
```

## GO Challenge 3

[`parse_goc3_json`](@ref) reads a GO Challenge 3 problem JSON into indexed
lookups (bus, device, line, transformer tables plus time series);
[`goc3_status_flags`](@ref) and [`goc3_add_status_flags!`](@ref) derive
startup/shutdown flags from unit commitment on/off trajectories. Pure Julia;
no C library needed.
