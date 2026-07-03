# Transmission networks

A transmission case parses into a [`BalancedNetwork`](@ref): an immutable view
of the case with raw MATPOWER units (MW/MVAr, degrees) and 1-based bus ids,
plus a live handle into the Rust core that the `to_*` transforms run off.

## Formats

Each format reads and writes, so any pair converts. A same-format round trip
is byte exact; a cross-format conversion reports fields the target cannot
represent as warnings.

| Format | Tokens | Extension |
|---|---|---|
| MATPOWER | `"matpower"`, `"m"` | `.m` |
| PSS/E revision 33 | `"psse"`, `"raw"` | `.raw` |
| PowerWorld | `"powerworld"`, `"aux"` | `.aux` |
| PowerModels.jl network data JSON | `"powermodels-json"`, `"powermodels"`, `"pm"` | `.json` |
| egret ModelData JSON | `"egret-json"`, `"egret"` | `.json` |
| PowerIO JSON transport | `"powerio-json"` | — |
| PyPSA static network CSV | `"pypsa-csv"` | directory |
| GridFM Parquet dataset | — (see [`read_gridfm`](@ref)) | directory |

The format is inferred from the extension unless `from` is given. egret and
PowerModels both use `.json`, so those two need the hint:

```julia
net   = parse_file("case14.m")
egret = parse_file("grid.json"; from="egret")
```

## Parsing

[`parse_file`](@ref) reads a path or an `IO`; [`parse_str`](@ref) reads
in-memory text (a `String` argument to `parse_file` is always a path);
[`from_json`](@ref) rebuilds from the JSON transport [`to_json`](@ref) writes.

```julia
net = parse_file("case14.m")
net = parse_file(IOBuffer(text), "matpower")
net = parse_str(text, "matpower")
net = from_json(to_json(net))
```

Whatever the reader could not represent or had to assume is retained on the
handle; read it with [`PowerIO.warnings`](@ref).

## Inspecting a case

The element tables mirror the Rust `BalancedNetwork` and are the stable
contract: raw source units, 1-based bus ids, out-of-service elements
retained. Consumers normalize as they see fit.

```julia
PowerIO.buses(net)          # id, kind, vm, va (deg), base_kv, vmax, vmin, ...
PowerIO.generators(net)     # bus, pg, qg, limits, cost, caps, in_service
PowerIO.branches(net)       # from, to, r, x, b, rates, tap, shift (deg), ...
PowerIO.loads(net)          # bus, p (MW), q (MVAr), in_service
PowerIO.shunts(net)
PowerIO.storage(net)
PowerIO.hvdc(net)

PowerIO.n_buses(net), PowerIO.n_branches(net), PowerIO.n_gens(net)
PowerIO.base_mva(net)
PowerIO.source_format(net)      # "Matpower", "Psse", ...
PowerIO.reference_bus_id(net)   # the slack bus id, or nothing
PowerIO.n_components(net)       # connected components of the in-service topology
PowerIO.is_radial(net)
```

## Normalizing

[`to_normalized`](@ref) derives a computation-ready copy: powers per unit,
angles in radians, tap `0 → 1`, out-of-service and isolated elements dropped,
source bus ids preserved, bus types inferred.

```julia
norm = to_normalized(net)
PowerIO.source_format(norm)   # "Normalized"
```

## Serializing

```julia
to_matpower(net)                    # ::String, byte exact when the input was MATPOWER
to_format(net, "powermodels-json")  # (text, warnings)
to_json(net)                        # the JSON transport
convert_file("case14.m", "psse")    # parse + write in one shot -> (text, warnings)
convert_str(text, "psse"; from="matpower")
write_pypsa_csv_folder(net, "out/") # the one directory-shaped writer
```

## Dense numeric arrays

[`to_dense`](@ref) pulls the numeric tables as dense typed arrays straight
from the C ABI extractors, skipping JSON entirely — the fast path for matrix
assembly:

```julia
d = to_dense(net)              # or to_dense("case14.m")
d.n, d.m, d.ng                 # bus / branch / generator counts
d.bus_ids                      # 1-based ids; row k of every per-bus table is bus_ids[k]
d.branch.from, d.branch.x
d.gen.bus, d.gen.pg
d.demand.pd, d.shunt.bs
d.reference_bus, d.n_components, d.is_radial
```

## Arrow export

[`to_arrow`](@ref) brings one table across the Arrow C Data Interface (needs
the library built with `--features arrow`; [`arrow_available`](@ref) reports
it). Raw selectors are `:bus`, `:branch`, `:gen`, `:load`, `:shunt`, and
`:switch`; normalized solver selectors are `:solver_bus`, `:solver_load`,
`:solver_shunt`, `:solver_branch`, `:solver_switch`, `:solver_arc`,
`:solver_gen`, `:solver_storage`, and `:solver_hvdc`.

```julia
t = to_arrow(net, :branch)              # NamedTuple of owned Julia Vectors
sb = to_arrow(net, :solver_bus)         # dense 0-based ids, per unit values
z = to_arrow(net, :branch; copy=false)  # zero-copy ArrowTable; keep it alive while reading
```

The default returns owned columns (Tables.jl shaped, flows into
`Arrow.write`, `DataFrame`, etc.) with no lifetime caveat. `copy=false`
returns a zero-copy [`ArrowTable`](@ref) whose columns view the producer's
memory.
