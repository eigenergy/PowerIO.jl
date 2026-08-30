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
[`to_dense`](@ref), [`to_matpower`](@ref), [`to_arrow`](@ref)) work from the live
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

"""
    warnings(net::BalancedNetwork) -> Vector{String}

The reader's findings as rendered `CODE: message` lines. Needs a live handle.
"""
function warnings(net::BalancedNetwork)
    h = _live_handle(net, "warnings")
    return String[string(d.code, ": ", d.message) for d in _handle_diagnostics(h)]
end

function Base.getproperty(net::BalancedNetwork, name::Symbol)
    name === :data && return _materialized_data(net)
    name === :name && return network_name(net)
    name === :source_format && return source_format(net)
    name === :warnings && return warnings(net)
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
    public = (:name, :source_format, :warnings, :base_mva, :base_frequency, :buses,
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
        "PowerIO.$fname: this BalancedNetwork has no live network handle (produce it with parse_file, parse_bytes, or from_json).")
    h.ptr == C_NULL && error(
        "PowerIO.$fname: this BalancedNetwork's handle was finalized; access the data you need " *
        "(e.g. net.data, to_json(net)) before calling finalize(net.handle).")
    return h
end

# Derive a normalized handle from a live one via `pio_balanced_network_normalize` (a read-only
# borrow of the source case, so the source handle stays valid). GC.@preserve:
# Julia frees an object after its last use, not at end of call, so without it a
# GC triggered between extracting `h.ptr` and the ccall could finalize `h` and
# hand the Rust side a freed pointer. Every helper that lowers a handle to a raw
# pointer carries the same guard.
const POWER_MODELS_ANGLE_BOUND_PAD = 1.0472

# `PioNormalizeOptions`, the extensible options struct `pio_balanced_network_normalize` reads.
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
    ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_balanced_network_normalize), Ptr{Cvoid},
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

# Serialize a bare network handle: wrap it as a module sharing the handle's
# records, then run the one module write. `want_findings=false` passes NULL
# for the findings channel.
function _format_from_handle(h::BalancedNetworkHandle, to::AbstractString, what::AbstractString;
                             want_warnings::Bool=true)
    lib = getfield(h, :lib)
    module_ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_of_balanced_network), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), h.ptr, err)
    end
    handle = StoredModule(module_ptr, lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    s = GC.@preserve handle _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_write_str), Cstring,
              (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              _module_ptr(handle), String(to), out_diagnostics, err)
    end
    text = _take_string(lib, s)
    findings = want_warnings ? _diagnostics_of(_ -> out_diagnostics[], lib) : Diagnostic[]
    want_warnings || out_diagnostics[] == C_NULL ||
        ccall(_library_symbol(lib, :pio_diagnostics_release), Cvoid, (Ptr{Cvoid},), out_diagnostics[])
    return (text, findings)
end

# `matpower` flows through the one string-keyed writer like every other format
# (v4 retired the per-format `pio_to_matpower`). The writer warns whenever the
# source was not MATPOWER, so discard the channel rather than collect it.
"""
    to_matpower(net::BalancedNetwork) -> String

Serialize `net` to MATPOWER `.m` text, byte exact when the input was MATPOWER. For a
file in one shot use [`convert_file`](@ref)`(path, "matpower")`.
"""
to_matpower(net::BalancedNetwork) =
    first(_format_from_handle(_live_handle(net, "to_matpower"), "matpower",
                              repr(network_name(net)); want_warnings=false))

"""
    to_format(net::BalancedNetwork, to) -> (text, warnings)
    to_format(net::MulticonductorNetwork, to) -> (text, warnings)

Serialize a parsed network to format `to` without reparsing the input file.
Returns the target text and any fidelity warnings, a `Vector{`[`Diagnostic`](@ref)`}`
whose elements read as `CODE: message` lines and carry the record's fields.
Dispatches on the handle type, so a [`MulticonductorNetwork`](@ref) writes the
distribution formats.
"""
to_format(net::BalancedNetwork, to::AbstractString) =
    _format_from_handle(_live_handle(net, "to_format"), to, repr(network_name(net)))


"""
    convert_file(path, to; from=nothing) -> (text, warnings)
    convert_file(MulticonductorNetwork, path, to; from=nothing) -> (text, warnings)

Convert `path` to format `to`, routing on the formats like [`parse_file`](@ref):
distribution tokens and `.dss` paths go through the multiconductor converter,
and a cross-model request (e.g. `.dss` to `"matpower"`) is a directed error —
lowering is explicit, through the package pass. Within the transmission family
supported writer pairs convert. A same format conversion is byte exact; a cross
format one reports whatever the target can't carry in `warnings`. Tokens
(case-insensitive): `"matpower"`/`"m"`, `"powermodels-json"`/`"powermodels"`/`"pm"`,
`"egret-json"`/`"egret"`, `"psse"`/`"raw"`, `"powerworld"`/`"aux"`,
`"pslf"`/`"epc"`, `"pandapower-json"`/`"pandapower"`, `"surge-json"`/`"surge"`,
`"pypsa-csv"`. `from` overrides extension inference (needed to tell egret,
PowerModels, pandapower, and Surge `.json` files apart). Pass
[`MulticonductorNetwork`](@ref) first to convert a distribution case.
"""
function convert_file(path::AbstractString, to::AbstractString; from=nothing)
    dist_to = _is_dist_format(to)
    dist_src = (from !== nothing && _is_dist_format(from)) ||
               (from === nothing && _is_dss_path(path))
    if dist_to
        # A balanced source cannot become multiconductor; a `.json`/unknown
        # source goes to the distribution converter, whose own inference and
        # errors apply.
        balanced_src = (from !== nothing && !_is_dist_format(from)) ||
                       (from === nothing &&
                        lowercase(splitext(String(path))[2]) in (".m", ".raw", ".aux", ".epc", ".pwb"))
        balanced_src && _cross_model_error("convert_file")
        return convert_file(MulticonductorNetwork, path, to; from=from)
    end
    dist_src && _cross_model_error("convert_file")
    lib = _lib()
    _ensure_compatible(lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    fromc = from === nothing ? C_NULL : String(from)
    s = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_convert_file), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Cvoid}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              path, fromc, to, C_NULL, out_diagnostics, err)
    end
    text = _take_string(lib, s)
    return (text, _diagnostics_of(_ -> out_diagnostics[], lib))
end
# Explicit transmission marker, symmetric with `convert_file(MulticonductorNetwork, ...)`.
convert_file(::Type{BalancedNetwork}, path::AbstractString, to::AbstractString; from=nothing) =
    convert_file(path, to; from=from)

"""
    convert_str(text, to; from) -> (text, warnings)
    convert_str(MulticonductorNetwork, text, to; from) -> (text, warnings)

Convert in-memory case `text` to format `to` — the string sibling of
[`convert_file`](@ref) (`pio_convert_str`). `from` is required for a transmission
case (there is no path to infer from): the source format token. Pass
[`MulticonductorNetwork`](@ref) first for a distribution case.
"""
function convert_str(text::AbstractString, to::AbstractString; from::AbstractString)
    dist_to = _is_dist_format(to)
    dist_from = _is_dist_format(from)
    dist_to && dist_from && return convert_str(MulticonductorNetwork, text, to; from=from)
    (dist_to || dist_from) && _cross_model_error("convert_str")
    lib = _lib()
    _ensure_compatible(lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    s = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_convert_str), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Cvoid}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              String(text), String(from), to, C_NULL, out_diagnostics, err)
    end
    out = _take_string(lib, s)
    return (out, _diagnostics_of(_ -> out_diagnostics[], lib))
end

"""
    write_pypsa_csv_folder(net::BalancedNetwork, out_dir) -> (out_dir, warnings)

Write `net` as a PyPSA CSV folder at `out_dir` — the
directory inverse of `parse_file(out_dir; from="pypsa-csv")`, where the
other writers (`to_format`, `convert_file`) emit a single text document. The
folder is staged completely and committed only when nothing exists at
`out_dir`; an existing entry there is refused rather than replaced. Returns
the output directory and any fidelity warnings the writer reports for fields the
PyPSA static-network CSV schema can't carry. Needs `net`'s live Rust handle
(from [`parse_file`](@ref)).
"""
function write_pypsa_csv_folder(net::BalancedNetwork, out_dir::AbstractString)
    h = _live_handle(net, "write_pypsa_csv_folder")
    lib = getfield(h, :lib)
    module_ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_of_balanced_network), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), h.ptr, err)
    end
    handle = StoredModule(module_ptr, lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    GC.@preserve handle _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_write_file), Cint,
              (Ptr{Cvoid}, Cstring, Cstring, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              _module_ptr(handle), "pypsa-csv", String(out_dir), out_diagnostics, err)
    end
    return (String(out_dir), _diagnostics_of(_ -> out_diagnostics[], lib))
end
