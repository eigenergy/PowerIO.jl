# Geographic layers

A **geo layer** is a coordinate document kept beside a case: points for buses
and routes for branches, in one coordinate space, keyed by element identity.
PowerIO reads five text forms into a [`GeoLayer`](@ref) and writes one back as
a GeoJSON FeatureCollection carrying a `powerio_geo` member that states the
coordinate space and the writer's version.

## Coordinates on a network

`bus.location` provides x/y coordinates, and `net.geo` names their coordinate
space. Balanced branches and multiconductor lines expose optional `route`
points. Geographic x/y means longitude/latitude; drawing x/y retains drawing
units. PowerIO IR preserves these values.

PowerIO reads supported PWB bus locations and the BMOPFTools proposed
Point/LineString values. Explicit BMOPF output writes geometry under the
schema-valid `extras.geojson` location. Same-type source emission retains
source bytes; after changes, the typed coordinates determine the output.

## Reading a layer

[`parse_geo`](@ref) reads a layer from text. Headerless buscoords CSV, aliased
CSV and JSON records, and GeoJSON Point and LineString features all read.
`name_hint` is a file name whose extension picks CSV against JSON when the
content alone is ambiguous.

```julia
using PowerIO

layer = parse_geo("1, -89.6, 40.6\n2, -89.2, 39.8\n")
layer.geojson        # the canonical FeatureCollection
layer.diagnostics    # what the reader found
```

A geographic file also parses as a module, so it serializes and emits through
the ordinary module methods:

```julia
m = parse("case.geo.json")   # PioModule{GeoLayer}
m.value.geojson
```

## Placing coordinates on a network

[`apply_geo_layer`](@ref) places a layer's coordinates on a balanced or
multiconductor network module. It derives a new module and leaves the input one
unchanged.

```julia
case = parse("case9.m")
placed, report = apply_geo_layer(case, layer)

placed.value.buses[1].location.x   # -89.6
case.value.buses[1].location       # nothing: the input module is unchanged

report.matched_buses
report.matched_branches
report.unmatched_features
report.unlocated_buses
report.unlocated_branches
report.notes
```

A second method takes the layer text directly:

```julia
placed, report = apply_geo_layer(case, read("case.geo.json", String))
```

Python exposes this as a method on the network. Here it takes and returns a
module, because the C entry point is module level and one call serves both
network kinds. A module holding anything but a network throws a
[`PowerIOError`](@ref) with code `"REQUEST.MODULE.WRONG_MODEL_KIND"`.

The derived module writes out like any other, so placed coordinates reach a
file through [`emit`](@ref) or [`serialize`](@ref).

## Reference

```@docs
GeoLayer
GeoApplyReport
parse_geo
apply_geo_layer
```
