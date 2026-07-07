"""
    TimeAxis

Period count, optional per-period durations (hours), and optional labels shared by every
[`OperatingPoint`](@ref) in an [`OperatingPointSeries`](@ref). Mirrors the Rust `TimeAxis`.
"""
struct TimeAxis
    periods::Int
    duration_hours::Vector{Float64}
    labels::Vector{String}
end

"""
    ElementUpdate

One sparse per-period field overwrite: `field` of the row identified by `source_uid` (or the
positional `row`) in `table` takes `value`. Mirrors the Rust `ElementUpdate`.
"""
struct ElementUpdate
    table::Symbol
    source_uid::Union{String,Nothing}
    row::Union{Int,Nothing}
    field::Symbol
    value::Any
end

"""
    OperatingPoint

One period's operating state: the zero-based period `index` and the sparse `updates` applied
to the base network for that period. Mirrors the Rust `OperatingPoint`.
"""
struct OperatingPoint
    index::Int
    updates::Vector{ElementUpdate}
end

"""
    OperatingPointSeries

Reserved skeleton for PowerIO's general, format-neutral multiperiod series — the Julia
binding of the powerio Rust `OperatingPointSeries` (`powerio-pkg/src/operating.rs`). It is a
[`TimeAxis`](@ref) plus a vector of [`OperatingPoint`](@ref)s, each a *sparse* set of
[`ElementUpdate`](@ref)s (per-period field overwrites on any table, replayed over a base
network). This is more general and more compact than the dense, loads-only [`LoadSeries`](@ref):
it carries changes to any field of any element, storing only what differs each period.

Not yet functional. The powerio C ABI exposes reading and materializing an existing series
(`pio_package_operating_points_json`, `pio_package_materialize_operating_point`) but not a
construct/attach path, so a series cannot yet be built from Julia. The constructor and
`materialize_operating_point_series` below throw until that C ABI lands; use [`LoadSeries`](@ref)
for multiperiod bus loads in the meantime. Unexported while it is a skeleton so a throwing
constructor is not advertised as usable.
"""
struct OperatingPointSeries
    time_axis::TimeAxis
    points::Vector{OperatingPoint}
end

# Forward declarations: zero-method generic functions reserve the names for the binding to
# implement once the C ABI exposes operating-point construct/attach.
function operating_point_series end
function materialize_operating_point_series end

const _OPS_UNAVAILABLE = "OperatingPointSeries is not yet available: the powerio C ABI " *
    "exposes reading/materializing a series but not construct/attach. Use PowerIO.LoadSeries " *
    "for multiperiod bus loads until that binding lands."

OperatingPointSeries(::BalancedNetwork, args...; kwargs...) = error(_OPS_UNAVAILABLE)
operating_point_series(args...; kwargs...) = error(_OPS_UNAVAILABLE)
materialize_operating_point_series(args...; kwargs...) = error(_OPS_UNAVAILABLE)
