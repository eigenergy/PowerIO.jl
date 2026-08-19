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
    if _exports_symbol(:pio_summary_json, lib)
        err = zeros(UInt8, _ERRLEN)
        s = GC.@preserve h ccall(_library_symbol(lib, :pio_summary_json), Cstring,
                                 (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
        s == C_NULL && error("PowerIO: could not serialize the balanced summary: " * _cstr(err))
        text = _take_string(lib, s)
        return JSON3.read(text)
    end
    data = JSON3.read(_to_json(h))
    refs = Int.(reference_bus_indices(BalancedNetwork(h)))
    ids = _handle_bus_ids(h)
    ref_ids = [Int(ids[i + 1]) for i in refs]
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
        warnings = length(_handle_warnings(h)),
    )
    components = Int(GC.@preserve h ccall(_library_symbol(lib, :pio_n_islands),
                                          Csize_t, (Ptr{Cvoid},), h.ptr))
    radial = (GC.@preserve h ccall(_library_symbol(lib, :pio_is_radial),
                                   Cint, (Ptr{Cvoid},), h.ptr)) != 0
    return JSON3.read(JSON3.write((;
        powerio_version = something(schema_versions().powerio_version, ""),
        name = _payload_value(data, :name, ""),
        source_format = _source_format_token(_payload_value(data, :source_format, "in-memory")),
        base_mva = _payload_value(data, :base_mva, 0.0),
        base_frequency = _payload_value(data, :base_frequency, 60.0),
        counts,
        topology = (;
            reference_bus_ids = ref_ids,
            reference_bus_indices = refs,
            n_components = components,
            is_radial = radial,
        ),
    )))
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
    parse_file(path; from=nothing) -> BalancedNetwork | MulticonductorNetwork
    parse_file(io::IO, format::AbstractString)
    parse_file(BalancedNetwork, path; from=nothing) -> BalancedNetwork
    parse_file(MulticonductorNetwork, path; from=nothing) -> MulticonductorNetwork

Parse a case. The bare verb routes on the format and returns the model the
file holds: transmission cases (MATPOWER, PSS/E, PowerWorld, PSLF EPC,
PowerModels JSON, egret JSON, pandapower JSON, PyPSA CSV folders, Surge JSON)
parse into a [`BalancedNetwork`](@ref), multiconductor distribution cases
(OpenDSS, PMD, BMOPF) into a [`MulticonductorNetwork`](@ref), and a `.pio.json`
package into whichever model its envelope declares.

From a file `path` the format is inferred: by extension (`.m`, `.raw`, `.aux`,
`.dss`, `.pio.json`), and for a bare `.json` by the same top level markers the
core parsers use (`pio_classify_str`), unless `from` is given. A bare `.json`
holding model JSON is read with [`from_json`](@ref); model JSON is not a case
format and has no format token. From an `io` stream the `format` is required
(there is no extension); parse in-memory text by wrapping it,
`parse_file(IOBuffer(text), "matpower")`.

Accepted format tokens (case-insensitive): `"matpower"`/`"m"`,
`"powermodels-json"`/`"powermodels"`/`"pm"`, `"egret-json"`/`"egret"`,
`"psse"`/`"raw"`, `"powerworld"`/`"aux"`, `"pslf"`/`"epc"`,
`"pandapower-json"`/`"pandapower"`, `"surge-json"`/`"surge"`,
`"pypsa-csv"`; distribution: `"dss"`/`"opendss"`, `"pmd"`/`"engineering"`,
`"bmopf"`.

The type marker forms pin the model when the routed return type would be
ambiguous to a reader: `parse_file(BalancedNetwork, path)` and
`parse_file(MulticonductorNetwork, path)` — the `parse(T, x)` idiom.
"""
function parse_file(path::AbstractString; from=nothing)
    if from !== nothing && _is_dist_format(from)
        return parse_file(MulticonductorNetwork, path; from=from)
    end
    if from === nothing
        _is_package_path(path) && return from_package(read_package(path))
        _is_dss_path(path) && return parse_file(MulticonductorNetwork, path)
        if lowercase(splitext(String(path))[2]) == ".json" && isfile(path)
            text = read(path, String)
            fam = _classify_family(text)
            fam === :distribution && return parse_file(MulticonductorNetwork, path)
            fam === :package && return from_package(read_package(path))
            # Model JSON is not a case format, so the core's parser refuses it.
            # Routing it here is the same convenience a package path gets.
            fam === MODEL_JSON_FAMILY && return from_json(text)
        end
    end
    h = _parse_handle(path; from=from)
    return BalancedNetwork(h)
end
function parse_file(io::IO, format::AbstractString)
    _is_dist_format(format) && return parse_str(MulticonductorNetwork, read(io, String), format)
    h = _parse_handle_str(read(io, String), format)
    return BalancedNetwork(h)
end
# Explicit transmission marker, symmetric with `parse_file(MulticonductorNetwork, ...)`:
# bypasses the format routing, so it reaches the balanced parser no matter the
# extension.
function parse_file(::Type{BalancedNetwork}, path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    return BalancedNetwork(h)
end

"""
    parse_str(text, format="matpower") -> BalancedNetwork | MulticonductorNetwork
    parse_str(MulticonductorNetwork, text, format) -> MulticonductorNetwork

Parse in-memory case text — the string sibling of `parse_file(io, format)`,
matching the Rust, Python, and C interfaces. A distribution `format` token
routes to the multiconductor parser, like the bare [`parse_file`](@ref).
"""
parse_str(text::AbstractString, format::AbstractString="matpower") =
    parse_file(IOBuffer(String(text)), format)
# Explicit transmission marker: bypasses the format routing, so it reaches the
# balanced parser no matter the token (symmetric with parse_file(BalancedNetwork, ...)).
function parse_str(::Type{BalancedNetwork}, text::AbstractString, format::AbstractString="matpower")
    h = _parse_handle_str(String(text), format)
    return BalancedNetwork(h)
end

"""
    parse_bytes(bytes, format) -> BalancedNetwork

Parse in-memory case bytes under an explicit `format`. Accepts every
[`parse_str`](@ref) token plus `"pwb"`: PowerWorld binary has no text form, so
this is the only way to read one without a file on disk. Text formats must be
UTF-8.
"""
function parse_bytes(bytes::AbstractVector{UInt8}, format::AbstractString)
    h = _parse_handle_bytes(bytes, format)
    return BalancedNetwork(h)
end
parse_bytes(::Type{BalancedNetwork}, bytes::AbstractVector{UInt8}, format::AbstractString) =
    parse_bytes(bytes, format)

"""
    from_json(text) -> BalancedNetwork

Rebuild a live [`BalancedNetwork`](@ref) from the JSON transport produced by
[`to_json`](@ref). The result has a Rust handle, so `to_*` transforms work on it.
"""
function from_json(text::AbstractString)
    h = _from_json_handle(text)
    return BalancedNetwork(h)
end

# The live Rust handle a BalancedNetwork-first transform needs; a manually constructed
# BalancedNetwork has none, and a finalized handle is non-`nothing` but null. Name the
# function that needs it, and separate the two null cases so the finalized one points
# at the fix (materialize before finalizing) instead of "reparse it".
function _live_handle(net::BalancedNetwork, fname::AbstractString)
    h = getfield(net, :handle)
    h === nothing && error(
        "PowerIO.$fname: this BalancedNetwork has no live network handle (produce it with parse_file, parse_str, or from_json).")
    h.ptr == C_NULL && error(
        "PowerIO.$fname: this BalancedNetwork's handle was finalized; access the data you need " *
        "(e.g. net.data, to_json(net)) before calling finalize(net.handle).")
    return h
end

# Derive a normalized handle from a live one via `pio_normalize` (a read-only
# borrow of the source case, so the source handle stays valid). GC.@preserve:
# Julia frees an object after its last use, not at end of call, so without it a
# GC triggered between extracting `h.ptr` and the ccall could finalize `h` and
# hand the Rust side a freed pointer. Every helper that lowers a handle to a raw
# pointer carries the same guard.
const POWER_MODELS_ANGLE_BOUND_PAD = 1.0472

# `PioNormalizeOptions`, the extensible options struct `pio_normalize` reads.
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
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_normalize), Ptr{Cvoid},
                               (Ptr{Cvoid}, Ref{PioNormalizeOptions}, Ptr{UInt8}, Csize_t),
                               h.ptr, opts, err, length(err))
    ptr == C_NULL && error("PowerIO.to_normalized: " * _cstr(err))
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

# `want_warnings=false` skips the diagnostics channel by passing NULL, which is
# how the C side is told to discard it. Passing a live ref and dropping it
# unread leaks the document the writer allocated into it.
function _format_from_handle(h::BalancedNetworkHandle, to::AbstractString, what::AbstractString;
                             want_warnings::Bool=true)
    lib = getfield(h, :lib)
    diagref = _diagref()
    diagarg = want_warnings ? diagref : Ptr{Ptr{UInt8}}(C_NULL)
    err = zeros(UInt8, _ERRLEN)
    # `opts` is the write-time options struct; C_NULL is every default, which
    # is what every Julia surface wants until one exposes the cost policies.
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_to_format), Cstring,
                             (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
                             h.ptr, String(to), C_NULL, diagarg, err, length(err))
    s == C_NULL && error("PowerIO.to_format: " * _cstr(err) * " ($what)")
    text = _take_string(lib, s)
    return (text, want_warnings ? _take_warnings(lib, diagref) : Diagnostic[])
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
    warnings(net::BalancedNetwork) -> Vector{String}
    warnings(net::MulticonductorNetwork) -> Vector{String}

The fidelity warnings retained on a live handle (`pio_warnings`) — what the reader
could not represent or had to assume. Empty for a handle-less [`BalancedNetwork`](@ref).

Each line reads `CODE: message`. Split at the first `": "`: the left side is a
stable dotted code (`READ.DSS.INCLUDE_REFUSED`) whose first segment names the
stage, and the right side is prose under no stability promise. Branch on the
code, never on the message. `pio_warnings` carries lines alone; the conversion
verbs return [`Diagnostic`](@ref)s, which reach the same code as a field.
"""
function warnings(net::BalancedNetwork)
    h = net.handle
    (h === nothing || h.ptr == C_NULL) && return String[]
    return _handle_warnings(h)
end

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
    diagref = _diagref()
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    # v4 argument order is (path, from, to), matching pio_to_format / pio_parse_str.
    fromc = from === nothing ? C_NULL : String(from)
    s = ccall(_library_symbol(lib, :pio_convert_file), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
              path, fromc, to, C_NULL, diagref, err, length(err))
    s == C_NULL && error("PowerIO.convert_file: " * _cstr(err))
    text = _take_string(lib, s)
    return (text, _take_warnings(lib, diagref))
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
    diagref = _diagref()
    err = zeros(UInt8, _ERRLEN)
    # v4 argument order is (text, from, to), matching pio_convert_file.
    s = ccall(_library_symbol(lib, :pio_convert_str), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
              String(text), String(from), to, C_NULL, diagref, err, length(err))
    s == C_NULL && error("PowerIO.convert_str: " * _cstr(err))
    out = _take_string(lib, s)
    return (out, _take_warnings(lib, diagref))
end

"""
    write_pypsa_csv_folder(net::BalancedNetwork, out_dir) -> (out_dir, warnings)

Write `net` as a PyPSA CSV folder under `out_dir` (created if absent) — the
directory inverse of `parse_file(out_dir; from="pypsa-csv")`, where the
other writers (`to_format`, `convert_file`) emit a single text document. Returns
the output directory and any fidelity warnings the writer reports for fields the
PyPSA static-network CSV schema can't carry. Needs `net`'s live Rust handle
(from [`parse_file`](@ref)).
"""
function write_pypsa_csv_folder(net::BalancedNetwork, out_dir::AbstractString)
    h = _live_handle(net, "write_pypsa_csv_folder")
    lib = getfield(h, :lib)
    diagref = _diagref()
    err = zeros(UInt8, _ERRLEN)
    # `pio_write_dir` is the generic directory writer; `pypsa-csv` is the one such
    # format today. Fallible `int` return (0 = success), the diagnostics/errbuf
    # convention of `pio_to_format`; the handle is preserved across the ccall.
    rc = GC.@preserve h ccall(_library_symbol(lib, :pio_write_dir), Int32,
                              (Ptr{Cvoid}, Cstring, Cstring, Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
                              h.ptr, "pypsa-csv", String(out_dir), C_NULL, diagref, err, length(err))
    rc == 0 || error("PowerIO.write_pypsa_csv_folder: " * _cstr(err))
    return (String(out_dir), _take_warnings(lib, diagref))
end
