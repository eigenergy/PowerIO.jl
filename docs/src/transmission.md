# Transmission networks

A transmission case parses into a [`BalancedNetwork`](@ref): a Julia object with
raw MATPOWER units (MW/MVAr, degrees), 1-based bus ids, and a live handle into
the Rust core that the `to_*` transforms run off.

## Formats

Each format parses and emits, so any pair converts. A same format round trip is
byte exact; cross format emission reports fields the target cannot represent
as diagnostics.

| Format | Tokens | Extension |
|---|---|---|
| MATPOWER | `"matpower"`, `"m"` | `.m` |
| PSS/E revisions 33, 34, and 35 | `"psse"`, `"raw"` | `.raw` |
| PowerWorld | `"powerworld"`, `"aux"` | `.aux` |
| PSLF EPC | `"pslf"`, `"epc"` | `.epc` |
| PowerModels.jl network data JSON | `"powermodels-json"`, `"powermodels"`, `"pm"` | `.json` |
| egret ModelData JSON | `"egret-json"`, `"egret"` | `.json` |
| pandapower JSON | `"pandapower-json"`, `"pandapower"` | `.json` |
| Surge JSON | `"surge-json"`, `"surge"` | `.json` |
| PyPSA static network CSV | `"pypsa-csv"` | directory |
| GridFM Parquet dataset | `"gridfm"` | directory |

The format is inferred from the extension unless `format` is given. Egret and
PowerModels both use `.json`, so those two need the hint:

```julia
case  = parse_file("case14.m")
egret = parse_file("grid.json"; format="egret")
```

## Parsing

[`parse_file`](@ref) parses a file or directory path into a [`PioModule`](@ref).
[`parse_text`](@ref) parses text already in memory.
The type parameter states the detected kind, and `m.value` is the typed value — a live
[`BalancedNetwork`](@ref) handle for a transmission case. [`from_json`](@ref)
rebuilds a bare value from the balanced model JSON returned by [`to_json`](@ref);
`parse_text(model_json; format="model-json")` returns the corresponding module.

```julia
m = parse_file("case14.m")        # ::PioModule{BalancedNetwork}
n_buses(m)                        # module forwarding is the ordinary path
net = m.value                     # explicit value access when useful
m = parse_text(text; name="case.m", format="matpower")
net = from_json(BalancedNetwork, to_json(net))
model_module = parse_text(to_json(net); name="case.json", format="model-json")
```

Whatever the parser could not represent or had to assume is retained on the
module; inspect it as typed records through `m.diagnostics`.

## Inspecting a case

The element tables mirror the Rust `BalancedNetwork`: raw source units,
1-based bus ids, out-of-service elements retained. Consumers normalize as they
see fit. Cheap metadata properties read a Rust summary and do not materialize
`net.data`; element table properties materialize the cached JSON payload.
REPL display uses the same summary path: compact display stays on one line, and
the multiline `text/plain` form prints counts, base values, topology, diagnostics,
and whether `net.data` has been materialized.

```julia
net.name
net.source_format
net.base_mva
net.buses                 # same as buses(net)

buses(m)                  # id, kind, vm, va (deg), base_kv, vmax, vmin, ...
generators(m)             # bus, pg, qg, limits, cost, caps, in_service
branches(m)               # from, to, r, x, b, rates, tap, shift (deg), ...
loads(m)                  # bus, p (MW), q (MVAr), in_service
shunts(m)
storage(m)
hvdc(m)

n_buses(m), n_branches(m), n_generators(m)
base_mva(m)
source_format(m)          # "matpower", "psse", ...
reference_bus_id(m)       # the slack bus id, or nothing
reference_bus_positions(m) # 1-based positions in dense bus order
n_islands(m)              # electrical islands in the in-service topology
is_radial(m)
to_graph(m)               # all buses, in-service branch edges
```

## Normalizing

[`to_normalized`](@ref) derives a computation-ready copy: powers per unit,
angles in radians, tap `0 → 1`, out-of-service and isolated elements dropped,
source bus ids preserved, bus types inferred.

```julia
norm = to_normalized(m)
source_format(norm)   # "normalized"

norm = to_normalized(net; clamp_angle_bounds=true, angle_bound_pad=pi / 3)
```

The angle clamp option repairs PowerModels style branch angle bounds during
normalization. The default `to_normalized(net)` preserves the source bounds.

## Emitting

```julia
matpower = emit(m, "matpower")           # byte exact when the input was MATPOWER
pm = emit(m, "powermodels-json")
matpower.text
matpower.diagnostics
emit(m, "pypsa-csv", "out/")            # directory output
to_json(m)                                # stored module document
to_json(m.value)                          # balanced network model JSON
```

## Dense numeric arrays

[`to_dense`](@ref) pulls the numeric tables as dense typed arrays straight
from the C ABI extractors without passing through JSON:

```julia
d = to_dense(m)                # or to_dense("case14.m")
d.n, d.m, d.ng                 # bus / branch / generator counts
d.bus_ids                      # 1-based ids; row k of every per-bus table is bus_ids[k]
d.branch.from, d.branch.x
d.gen.bus, d.gen.pg
d.demand.pd, d.shunt.bs
d.reference_bus, d.n_components, d.is_radial
d.bus_ids[d.reference_bus]     # reference_bus is a 1-based index into bus_ids
```

## Arrow export

[`to_arrow`](@ref) brings one table across the Arrow C Data Interface (needs
the library built with `--features arrow`; [`arrow_available`](@ref) reports
it). Raw selectors are `:bus`, `:branch`, `:gen`, `:load`, `:shunt`, and
`:switch`. Specialized normalized tables are available for consumers that need
the Rust row index space directly.

```julia
t = to_arrow(m, :branch)                 # NamedTuple of owned Julia Vectors
z = to_arrow(m, :branch; copy=false)     # zero copy ArrowTable; close when done
```

The default returns owned columns (Tables.jl compatible, flows into
`Arrow.write`, `DataFrame`, etc.) with no lifetime caveat. `copy=false`
returns a zero copy [`ArrowTable`](@ref) whose columns reference the producer's
memory. Extracted columns root the buffers themselves; reads after `close(z)`
throw a Julia error.

See [Matrices](matrices.md) for the Rust computed sparse matrix API.
