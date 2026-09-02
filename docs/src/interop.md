# Interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | [`to_powermodels`](@ref), [`from_powermodels`](@ref) through PowerModels JSON |
| ExaModelsPower.jl | out | [`to_powerdata`](@ref), [`to_ac_power_data`](@ref), `LoadSeries` |
| GridFM | both | `parse` of a Parquet dataset, `emit(m, "gridfm")` |
| PyPSA | both | `parse` of a CSV folder, `emit(m, "pypsa-csv", dir)` |
| PowerModelsDistribution.jl | both | `emit(m, "pmd")`, `parse` of PMD JSON |
| BMOPF | both | `emit(m, "bmopf")`, `parse` of BMOPF JSON |
| Other PowerIO consumers | both | `serialize`, `deserialize` (PowerIO IR) |

## PowerModels.jl

`to_powermodels` writes the module through the PowerModels JSON writer and
returns the network data dictionary PowerModels.jl consumes: per unit powers,
radian angles, string keyed component tables. `from_powermodels` parses such a
dictionary (or its JSON text) back into a `PioModule{BalancedNetwork}`.

```julia
case = parse("case14.m")
data = to_powermodels(case)
data["bus"]["1"]["bus_type"]              # 3
back = from_powermodels(data)             # PioModule{BalancedNetwork}
```

[`build_powermodels_ref`](@ref) builds the flat reference dictionary
(`:bus`, `:gen`, `:branch`, `:arcs`, `:bus_arcs`, `:ref_buses`, ...) that
PowerModels models index, and
[`repair_powermodels_angle_bounds!`](@ref) clamps branch angle difference
bounds the way `PowerModels.correct_voltage_angle_differences!` does.

## ExaModelsPower.jl

`to_powerdata` returns ExaPowerIO's `PowerData` layout (`bus`, `gen`,
`branch`, `arc`, `storage` rows with the fields ExaModelsPower reads);
`to_ac_power_data` adds the bound and initial value vectors its `build_*_opf`
functions consume. Powers are per unit, angles are radians, and bus references
are positions in the bus table.

```julia
data = to_ac_power_data("case118.m")
data.ref_buses
data.pmax
```

`PowerIO.LoadSeries` builds dense per bus load matrices over several periods
for the multiperiod models, from a matrix in MW, a per period multiplier, an
id keyed table, or two files.

## GridFM

A GridFM Parquet dataset parses into a `ScenarioSet{BalancedNetwork}`; each
scenario is a network. `emit(m, "gridfm", dir)` writes a dataset. Both need a
powerio library built with the `gridfm` feature; the release binaries include
it, and a build without it reports a coded parse error naming the feature.

## PowerIO IR

`serialize` and `deserialize` pass a complete module, with its diagnostics and
history, to another PowerIO consumer in Rust, Python, Julia, or C. The document
shape is `"schema": "powerio.module"`, `"version": 1`.

```@docs
to_powermodels
from_powermodels
build_powermodels_ref
repair_powermodels_angle_bounds!
to_powerdata
to_ac_power_data
PowerIO.LoadSeries
PowerIO.n_periods
PowerIO.demands_mw
PowerIO.read_load_series
```
