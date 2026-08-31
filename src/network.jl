# --- public API ---------------------------------------------------------

"""
    BalancedNetwork

A parsed balanced transmission case. Values stay in raw MATPOWER units with
1-based bus ids, mirroring `powerio`'s `BalancedNetwork`: buses, loads, shunts,
branches, generators, storage, and hvdc tables plus `base_mva`, `name`, and
`source_format`.

A `BalancedNetwork` from [`parse_file`](@ref) keeps a live Rust
[`BalancedNetworkHandle`](@ref) (`net.handle`) and leaves `net.data` empty until
the first rich payload access. The first `net.data` access reads the materialized
JSON payload through the C ABI and caches it. The `to_*` transforms ([`to_normalized`](@ref),
[`to_dense`](@ref), [`to_arrow`](@ref)) work from the live
handle. The handle's finalizer frees the Rust case once the `BalancedNetwork` is
unreachable. A `BalancedNetwork` constructed from a bare `JSON3.Object` has
`handle === nothing`; table access and [`to_json`](@ref) work on it, while
handle-only transforms error.

Because `data` is lazy, explicitly calling `finalize(net.handle)` before the first
`net.data` access leaves nothing to read: the data-backed accessors (`net.data`,
`n_buses`, `show`, `to_json`) then raise a "handle was finalized" error. Access the
values you need before finalizing the handle; letting the finalizer run at GC is the
normal path and never hits this.
"""
mutable struct BalancedNetwork
    data::Union{JSON3.Object,Nothing}
    handle::Union{BalancedNetworkHandle,Nothing}
    summary::Union{JSON3.Object,Nothing}
end
BalancedNetwork(data::JSON3.Object) = BalancedNetwork(data, nothing, nothing)
BalancedNetwork(h::BalancedNetworkHandle) = BalancedNetwork(nothing, h, nothing)
BalancedNetwork(data::Union{JSON3.Object,Nothing}, handle::Union{BalancedNetworkHandle,Nothing}) =
    BalancedNetwork(data, handle, nothing)

function _materialized_data(net::BalancedNetwork)
    data = getfield(net, :data)
    data !== nothing && return data
    h = _live_handle(net, "data")
    data = JSON3.read(_to_json(h))
    setfield!(net, :data, data)
    return data
end

function Base.getproperty(net::BalancedNetwork, name::Symbol)
    name === :data && return _materialized_data(net)
    name === :name && return network_name(net)
    name === :source_format && return source_format(net)
    name === :base_mva && return base_mva(net)
    name === :base_frequency && return base_frequency(net)
    name === :buses && return buses(net)
    name === :branches && return branches(net)
    name === :generators && return generators(net)
    name === :loads && return loads(net)
    name === :shunts && return shunts(net)
    name === :storage && return storage(net)
    name === :hvdc && return hvdc(net)
    name === :switches && return net.data.switches
    name === :transformers_3w && return net.data.transformers_3w
    name === :areas && return net.data.areas
    return getfield(net, name)
end

function Base.propertynames(::BalancedNetwork, private::Bool=false)
    public = (:name, :source_format, :base_mva, :base_frequency, :buses,
              :branches, :generators, :loads, :shunts, :storage, :hvdc,
              :switches, :transformers_3w, :areas, :data)
    return private ? (public..., :handle, :summary) : public
end

function _balanced_summary_json(h::BalancedNetworkHandle)
    lib = getfield(h, :lib)
    text = GC.@preserve h begin
        raw = _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_balanced_network_summary_json), Cstring,
                  (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), h.ptr, err)
        end
        _take_string(lib, raw)
    end
    return JSON3.read(text)
end

_payload_value(data::JSON3.Object, key::Symbol, default) =
    haskey(data, key) ? getproperty(data, key) : default

# Model JSON written before powerio 0.9 spells `source_format` as the bare Rust
# variant name; 0.9 writes the same lowercase token every `from` accepts. Read
# both, report the token.
const _LEGACY_SOURCE_FORMATS = Dict(
    "Matpower" => "matpower",
    "PowerModelsJson" => "powermodels-json",
    "EgretJson" => "egret-json",
    "Psse" => "psse",
    "PowerWorld" => "powerworld",
    "PandapowerJson" => "pandapower-json",
    "Pslf" => "pslf",
    "PowerWorldBinary" => "powerworld-pwb",
    "InMemory" => "in-memory",
    "Normalized" => "normalized",
    "Gridfm" => "gridfm",
    "PypsaCsv" => "pypsa-csv",
    "Goc3Json" => "goc3-json",
    "SurgeJson" => "surge-json",
    "DeepMindOpfDataJson" => "opfdata-json",
)

_source_format_token(value) =
    value isa AbstractString ? get(_LEGACY_SOURCE_FORMATS, String(value), String(value)) : value

# A missing key and an explicit JSON `null` both count as zero, so a summary
# never throws on a document an accessor tolerates.
function _payload_len(data::JSON3.Object, key::Symbol)
    value = _payload_value(data, key, nothing)
    return value === nothing ? 0 : length(value)
end

function _summary_from_data(data::JSON3.Object, ::Type{BalancedNetwork})
    reference_ids = Int[]
    for bus in _payload_value(data, :buses, ())
        _payload_value(bus, :kind, nothing) == "REF" && push!(reference_ids, Int(bus.id))
    end
    counts = (;
        buses = _payload_len(data, :buses),
        loads = _payload_len(data, :loads),
        shunts = _payload_len(data, :shunts),
        branches = _payload_len(data, :branches),
        switches = _payload_len(data, :switches),
        generators = _payload_len(data, :generators),
        storage = _payload_len(data, :storage),
        hvdc = _payload_len(data, :hvdc),
        transformers_3w = _payload_len(data, :transformers_3w),
        areas = _payload_len(data, :areas),
        warnings = _payload_len(data, :warnings),
    )
    return JSON3.read(JSON3.write((;
        powerio_version = something(schema_versions().powerio_version, ""),
        name = _payload_value(data, :name, ""),
        source_format = _source_format_token(_payload_value(data, :source_format, "in-memory")),
        base_mva = _payload_value(data, :base_mva, 0.0),
        base_frequency = _payload_value(data, :base_frequency, 60.0),
        counts,
        topology = (;
            reference_bus_ids = reference_ids,
            reference_bus_indices = nothing,
            n_components = nothing,
            is_radial = nothing,
        ),
    )))
end

function _summary(net::BalancedNetwork)
    summary = getfield(net, :summary)
    summary !== nothing && return summary
    h = getfield(net, :handle)
    if h !== nothing && h.ptr != C_NULL
        summary = _balanced_summary_json(h)
    else
        summary = _summary_from_data(net.data, BalancedNetwork)
    end
    setfield!(net, :summary, summary)
    return summary
end



"""
    from_json(text) -> BalancedNetwork

Rebuild a live [`BalancedNetwork`](@ref) from the JSON transport produced by
[`to_json`](@ref). The result has a Rust handle, so `to_*` transforms work on it.
"""
function from_json(text::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _network_free_fn(lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_balanced_network_from_json), Ptr{Cvoid},
              (Cstring, Ref{Ptr{Cvoid}}), String(text), err)
    end
    return BalancedNetwork(BalancedNetworkHandle(ptr, lib))
end

# The live Rust handle a BalancedNetwork-first transform needs; a manually constructed
# BalancedNetwork has none, and a finalized handle is non-`nothing` but null. Name the
# function that needs it, and separate the two null cases so the finalized one points
# at the fix (materialize before finalizing) instead of "reparse it".
function _live_handle(net::BalancedNetwork, fname::AbstractString)
    h = getfield(net, :handle)
    h === nothing && error(
        "PowerIO.$fname: this BalancedNetwork has no live network handle (produce it with parse_file, parse_text, or from_json).")
    h.ptr == C_NULL && error(
        "PowerIO.$fname: this BalancedNetwork's handle was finalized; access the data you need " *
        "(e.g. net.data, to_json(net)) before calling finalize(net.handle).")
    return h
end

# Derive a normalized handle from a live one through the preferred C
# transformation (a read-only borrow of the source case, so the source handle
# stays valid). GC.@preserve:
# Julia frees an object after its last use, not at end of call, so without it a
# GC triggered between extracting `h.ptr` and the ccall could finalize `h` and
# hand the Rust side a freed pointer. Every helper that lowers a handle to a raw
# pointer carries the same guard.
const POWER_MODELS_ANGLE_BOUND_PAD = 1.0472

# `PioNormalizeOptions`, the extensible options struct the native transform reads.
# `struct_size` first, appended fields only, and a zero filled struct is every
# default: a zero `angle_bound_pad` is not a legal pad, so it means the default.
struct PioNormalizeOptions
    struct_size::Csize_t
    clamp_angle_bounds::Cint
    reserved::Cint
    angle_bound_pad::Cdouble
end

@assert sizeof(PioNormalizeOptions) == 2 * sizeof(Csize_t) + sizeof(Cdouble) "PioNormalizeOptions size mismatch"

function _normalize_handle(h::BalancedNetworkHandle;
                           clamp_angle_bounds::Bool=false,
                           angle_bound_pad::Union{Nothing,Real}=nothing)
    lib = getfield(h, :lib)
    _network_free_fn(lib)
    opts = PioNormalizeOptions(sizeof(PioNormalizeOptions),
                               clamp_angle_bounds ? Cint(1) : Cint(0), Cint(0),
                               angle_bound_pad === nothing ? 0.0 : Cdouble(angle_bound_pad))
    symbol = _preferred_symbol(:pio_balanced_network_to_normalized,
                               :pio_balanced_network_normalize, lib)
    ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{PioNormalizeOptions}, Ref{Ptr{Cvoid}}),
              h.ptr, opts, err)
    end
    return BalancedNetworkHandle(ptr, lib)
end

"""
    to_normalized(net::BalancedNetwork; clamp_angle_bounds=false, angle_bound_pad=nothing) -> BalancedNetwork

A computation-ready copy of `net`: per unit (powers ÷ `base_mva`), angles in
radians, transformer tap `0 → 1`, out-of-service and isolated elements dropped,
source bus ids preserved, and bus types inferred (a bus with a surviving generator
keeps `REF` if the source marked it so, else becomes `PV`; a generator-less bus
becomes `PQ`). `source_format` of the result is `"normalized"`.

Needs `net`'s live Rust handle (from [`parse_file`](@ref)). Errors if `base_mva` is
not positive or no reference bus can be established. `clamp_angle_bounds=true`
also applies the PowerModels angle difference repair in the Rust normalize pass.
"""
function to_normalized(net::BalancedNetwork; clamp_angle_bounds::Bool=false,
                       angle_bound_pad::Union{Nothing,Real}=nothing)
    h = _live_handle(net, "to_normalized")
    hn = _normalize_handle(h; clamp_angle_bounds=clamp_angle_bounds,
                           angle_bound_pad=angle_bound_pad)
    return BalancedNetwork(hn)
end

"""
    to_json(net::BalancedNetwork) -> String

Serialize `net` to the C ABI's JSON transport, the same text [`from_json`](@ref)
reads back. Uses the live handle when present, else the cached `net.data`.
"""
function to_json(net::BalancedNetwork)
    h = getfield(net, :handle)
    # With a live handle, serialize straight from Rust. Otherwise fall back to the
    # payload: a handleless BalancedNetwork carries `data` eagerly, and a live one
    # caches `data` on first access. The only gap is a handle finalized before that
    # first access — `net.data` then re-materializes through the freed handle and
    # `_live_handle` raises the "finalized" error; materialize before finalizing.
    return (h === nothing || h.ptr == C_NULL) ? JSON3.write(net.data) : _to_json(h)
end
