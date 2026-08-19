# Multiconductor distribution API over the C ABI (`pio_dist_*`, powerio-capi
# built `--features dist`).
#
# Transmission cases (balanced positive sequence) flow through `BalancedNetwork`
# and multiconductor unbalanced cases through `MulticonductorNetwork` — a
# different model on its own handle, parsed from and written to OpenDSS
# (`"dss"`), PowerModelsDistribution ENGINEERING JSON (`"pmd"`), and the IEEE
# BMOPF Taskforce JSON (`"bmopf"`). The two share the verbs: the bare verbs
# route on the format (see `parse_file`), the type marker forms
# (`parse_file(MulticonductorNetwork, path)`) stay as the explicit spelling,
# and `to_format` / `warnings` dispatch on the network type.
#
# Like `BalancedNetwork`, a parsed `MulticonductorNetwork` keeps a live Rust
# handle and leaves the element tables (`net.data`) unmaterialized until first
# access. The tables come from `pio_dist_to_json`: the materialized model JSON, the same
# object a `.pio.json` document carries under `model.multiconductor_network`.
# That JSON is deliberately not a case format the converter knows — `.pio.json`
# carries cases between PowerIO consumers with their metadata, BMOPF JSON is the
# exchange format for everything else.
#
# EXPERIMENTAL: the `pio_dist_*` signatures carry their own
# `PIO_DIST_ABI_VERSION` starting with powerio v0.3.1. PowerIO.jl requires that
# version before calling distribution entry points. The functions ship only
# with the dist feature (on by default in the released binaries), and full data
# materialization additionally needs the pkg feature; `dist_available()` checks
# the symbol and the reported dist ABI version.

# `pio_dist_network_free`, memoized per resolved path — the `_network_free_fn`
# story for distribution handles (a `set_library!` swap must not free across
# allocators; the pinned dlopen handle keeps the pointer valid for live finalizers).
const _DIST_FREE_FN = Ref{Ptr{Cvoid}}(C_NULL)
const _DIST_FREE_FN_LIB = Ref{String}("")
function _dist_network_free_fn(lib::AbstractString=_lib())
    lib = String(lib)
    if _DIST_FREE_FN[] == C_NULL || _DIST_FREE_FN_LIB[] != lib
        _DIST_FREE_FN[] = _library_symbol(lib, :pio_dist_network_free)
        _DIST_FREE_FN_LIB[] = lib
    end
    return _DIST_FREE_FN[]
end

"""
    MulticonductorNetworkHandle

Opaque handle to a parsed multiconductor distribution case inside the Rust
core, the distribution sibling of [`BalancedNetworkHandle`](@ref). Freed by its
finalizer; you normally go straight to [`parse_file`](@ref), which returns a
[`MulticonductorNetwork`](@ref) carrying the handle and lazily materialized
element tables.
"""
mutable struct MulticonductorNetworkHandle
    ptr::Ptr{Cvoid}
    lib::String
    function MulticonductorNetworkHandle(ptr::Ptr{Cvoid}, lib::AbstractString=_lib())
        ptr == C_NULL && error("PowerIO: null distribution network handle")
        # Resolve the free fn before `new`: a failed lookup must not strand a
        # handle with no finalizer attached.
        lib = String(lib)
        free = _dist_network_free_fn(lib)
        h = new(ptr, lib)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(free, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

Base.show(io::IO, h::MulticonductorNetworkHandle) =
    print(io, "MulticonductorNetworkHandle(", h.ptr == C_NULL ? "freed" : "live", ")")

"""
    MulticonductorNetwork

A parsed multiconductor distribution case. `parse_file` and `parse_str` keep a
live Rust handle and leave `net.data` empty until first table access. The first
`net.data` access reads the `pio-payload-multiconductor/1` JSON payload:
`buses`, `linecodes`, `lines`, `switches`, `transformers`, `loads`,
`generators`, `ibrs`, `control_profiles`, `shunts`, `capacitors`, `sources`,
`untyped`, plus `base_frequency`, `name`, `source_format`, and parse
`warnings`. The writer omits `ibrs`, `control_profiles`, and `capacitors`
when they are empty; the accessors read a missing one as an empty table.
String bus ids, ordered string terminal names, SI units, radians.

Build one with [`parse_file`](@ref)`("feeder.dss")` (the bare verb routes on
the format) or the explicit `parse_file(MulticonductorNetwork, path)`. A
`MulticonductorNetwork` constructed from a bare payload object has
`handle === nothing`; the accessors work on it, but the handle transforms
([`to_format`](@ref), [`to_package`](@ref)) error. JSON carry with provenance
is [`to_package`](@ref) / [`from_package`](@ref); exchange with tools outside
PowerIO is `to_format(net, "bmopf")`.

As on [`BalancedNetwork`](@ref), `data` is lazy: `finalize(net.handle)` before the
first `net.data` access leaves the data-backed accessors with nothing to read and
they raise a "handle was finalized" error. Access what you need before finalizing;
the finalizer running at GC is the normal path and never hits this.
"""
mutable struct MulticonductorNetwork
    data::Union{JSON3.Object,Nothing}
    handle::Union{MulticonductorNetworkHandle,Nothing}
    summary::Union{JSON3.Object,Nothing}
end
MulticonductorNetwork(data::JSON3.Object) = MulticonductorNetwork(data, nothing, nothing)
MulticonductorNetwork(data::JSON3.Object, handle::Union{MulticonductorNetworkHandle,Nothing}) =
    MulticonductorNetwork(data, handle, nothing)
MulticonductorNetwork(h::MulticonductorNetworkHandle) = MulticonductorNetwork(nothing, h, nothing)

function _materialized_data(net::MulticonductorNetwork)
    data = getfield(net, :data)
    data !== nothing && return data
    h = _live_dist_handle(net, "data")
    data = _dist_data(h)
    setfield!(net, :data, data)
    return data
end

# Element tables, in the order `powerio-dist`'s `DistNetwork` declares
# them. All table surfaces derive from this tuple.
const _MC_TABLE_NAMES = (:buses, :linecodes, :lines, :switches, :transformers, :loads,
                         :generators, :ibrs, :control_profiles, :shunts, :capacitors,
                         :sources, :untyped)

# The writer omits these tables when empty (serde `skip_serializing_if`),
# and `capacitors` first shipped with powerio v0.8, so a missing key reads
# as an empty table. Every other table always serializes; a missing one
# marks a wrong-shaped document and stays a `KeyError`.
const _MC_OPTIONAL_TABLES = (:ibrs, :control_profiles, :capacitors)

function _mc_table(net::MulticonductorNetwork, name::Symbol)
    data = net.data
    if name in _MC_OPTIONAL_TABLES
        table = _payload_value(data, name, nothing)
        return table === nothing ? () : table
    end
    return getproperty(data, name)
end

# One reader per scalar property; `getproperty` and `propertynames` both
# derive from this table, so the two surfaces cannot drift.
const _MC_SCALAR_READERS = (; name = network_name, source_format = source_format,
                            warnings = warnings, base_frequency = base_frequency)
const _MC_SCALARS = keys(_MC_SCALAR_READERS)

# `show` hides these tables when empty; the base tables always print.
const _MC_SHOWN_IF_NONEMPTY = (:ibrs, :control_profiles, :capacitors, :untyped)
const _MC_ALWAYS_SHOWN = filter(!in(_MC_SHOWN_IF_NONEMPTY), _MC_TABLE_NAMES)

function Base.getproperty(net::MulticonductorNetwork, name::Symbol)
    name === :data && return _materialized_data(net)
    reader = get(_MC_SCALAR_READERS, name, nothing)
    reader === nothing || return reader(net)
    name in _MC_TABLE_NAMES && return _mc_table(net, name)
    return getfield(net, name)
end

function Base.propertynames(::MulticonductorNetwork, private::Bool=false)
    public = (_MC_SCALARS..., _MC_TABLE_NAMES..., :data)
    return private ? (public..., :handle, :summary) : public
end


"""
    dist_available() -> Bool

True if the resolved C library exports `pio_dist_parse_file` (built `--features
dist`, on by default in the released binaries) and reports the distribution ABI
version this binding targets.
"""
function dist_available()
    _exports_symbol(:pio_dist_parse_file) || return false
    try
        _ensure_dist_compatible()
        return true
    catch e
        @debug "PowerIO: distribution API unavailable or incompatible" exception = (e, catch_backtrace())
        return false
    end
end

_dist_graph_available() =
    _exports_symbol(:pio_dist_graph_json)

const PIO_DIST_ABI_VERSION = UInt32(1)

"""
    dist_abi_version() -> UInt32

The distribution C ABI version reported by `pio_dist_abi_version()`. Compared
against `PIO_DIST_ABI_VERSION`, the distribution ABI this binding targets.
"""
dist_abi_version() = dist_abi_version(_lib())
function dist_abi_version(lib::AbstractString)
    _ensure_compatible(lib)
    return ccall(_library_symbol(lib, :pio_dist_abi_version), UInt32, ())
end

function _ensure_dist_compatible(lib::AbstractString=_lib())
    lib = String(lib)
    _ensure_compatible(lib)
    got = try
        dist_abi_version(lib)
    catch e
        error("PowerIO: the C ABI at \"$lib\" has no pio_dist_abi_version; " *
              "use powerio-capi v0.3.1 built with `--features dist`. Underlying: $e")
    end
    got == PIO_DIST_ABI_VERSION || error(
        "PowerIO: distribution C ABI version mismatch: the library at \"$lib\" reports dist ABI $got, " *
        "this PowerIO.jl targets dist ABI $(PIO_DIST_ABI_VERSION). Update the powerio-capi " *
        "artifact or local library.")
    return
end

# --- format routing -------------------------------------------------------
#
# The bare verbs route between the two models on format tokens and file
# extensions. The token set mirrors the core's name tables
# (powerio-dist/src/convert.rs `dist_target_from_name` and
# powerio/src/format/routing.rs `distribution_format_from_name`); the
# drift-canary test feeds every claimed token back through the core.

_canonical_format_key(s) = replace(lowercase(String(s)), "-" => "", "_" => "")
const _DIST_FORMAT_KEYS = Set(["dss", "opendss", "pmd", "pmdjson", "engineering",
                               "bmopf", "bmopfjson"])
_is_dist_format(s) = _canonical_format_key(s) in _DIST_FORMAT_KEYS
_is_dss_path(p) = lowercase(splitext(String(p))[2]) == ".dss"
_is_package_path(p) = endswith(lowercase(String(p)), ".pio.json")

# The directed error for a cross-model conversion request. There is no
# implicit lowering: multiconductor → balanced picks a base_mva and drops
# per-phase detail, so the explicit package pass owns it.
_cross_model_error(fname::AbstractString) = error(
    "PowerIO.$fname: no implicit conversion between the multiconductor and balanced " *
    "models. Lower explicitly: to_package(net) |> lower_multiconductor_to_balanced " *
    "|> from_package, then serialize the balanced result.")

# --- parse and materialize ------------------------------------------------

function _dist_parse_handle(path::AbstractString; from=nothing)
    lib = _lib()
    _ensure_dist_compatible(lib)
    _dist_network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : String(from)
    ptr = try
        ccall(_library_symbol(lib, :pio_dist_parse_file), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              path, fromc, err, length(err))
    catch e
        _feature_call_error("parse_file", "pio_dist_parse_file", "dist", e)
    end
    ptr == C_NULL && error("PowerIO.parse_file(MulticonductorNetwork): " * _cstr(err))
    return MulticonductorNetworkHandle(ptr, lib)
end

function _dist_parse_handle_str(text::AbstractString, format::AbstractString)
    lib = _lib()
    _ensure_dist_compatible(lib)
    _dist_network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall(_library_symbol(lib, :pio_dist_parse_str), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), String(format), err, length(err))
    catch e
        _feature_call_error("parse_str", "pio_dist_parse_str", "dist", e)
    end
    ptr == C_NULL && error("PowerIO.parse_str(MulticonductorNetwork): " * _cstr(err))
    return MulticonductorNetworkHandle(ptr, lib)
end

# Materialize the element tables of a live handle with `pio_dist_to_json`,
# returning the model JSON a `.pio.json` document carries under
# `model.multiconductor_network`.
function _dist_data(h::MulticonductorNetworkHandle)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_dist_to_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    s == C_NULL && error("PowerIO: could not serialize the multiconductor model: " * _cstr(err))
    text = _take_string(lib, s)
    return JSON3.read(text)
end

function _summary(h::MulticonductorNetworkHandle)
    lib = getfield(h, :lib)
    if _exports_symbol(:pio_dist_summary_json, lib)
        err = zeros(UInt8, _ERRLEN)
        s = GC.@preserve h ccall(_library_symbol(lib, :pio_dist_summary_json), Cstring,
                                 (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
        s == C_NULL && error("PowerIO: could not serialize the multiconductor summary: " * _cstr(err))
        text = _take_string(lib, s)
        return JSON3.read(text)
    end
    return nothing
end

function _summary_from_data(data::JSON3.Object, ::Type{MulticonductorNetwork})
    count_keys = (_MC_TABLE_NAMES..., :warnings)
    counts = NamedTuple{count_keys}(map(k -> _payload_len(data, k), count_keys))
    return JSON3.read(JSON3.write((;
        powerio_version = something(schema_versions().powerio_version, ""),
        name = _payload_value(data, :name, ""),
        source_format = _payload_value(data, :source_format, "InMemory"),
        base_frequency = _payload_value(data, :base_frequency, 60.0),
        counts,
    )))
end

function _summary(net::MulticonductorNetwork)
    summary = getfield(net, :summary)
    summary !== nothing && return summary
    h = getfield(net, :handle)
    if h !== nothing && h.ptr != C_NULL
        summary = _summary(h)
        if summary !== nothing
            setfield!(net, :summary, summary)
            return summary
        end
        summary = _summary_from_data(_dist_data(h), MulticonductorNetwork)
        setfield!(net, :summary, summary)
        return summary
    end
    summary = _summary_from_data(net.data, MulticonductorNetwork)
    setfield!(net, :summary, summary)
    return summary
end

# The live Rust handle a MulticonductorNetwork-first transform needs; a
# payload-only network has none, and a finalized handle is non-`nothing` but
# null. Name the function that needs it, and split the two null cases so the
# finalized one points at the fix (materialize before finalizing), matching
# `_live_handle` for BalancedNetwork.
function _live_dist_handle(net::MulticonductorNetwork, fname::AbstractString)
    h = getfield(net, :handle)
    h === nothing && error(
        "PowerIO.$fname: this MulticonductorNetwork has no live network handle " *
        "(produce it with parse_file, parse_str, or from_package).")
    h.ptr == C_NULL && error(
        "PowerIO.$fname: this MulticonductorNetwork's handle was finalized; access the data " *
        "you need (e.g. net.data) before calling finalize(net.handle).")
    return h
end

"""
    parse_file(MulticonductorNetwork, path; from=nothing) -> MulticonductorNetwork

Parse a distribution case file — the explicit form of the format-routed
[`parse_file`](@ref)`(path)`, selected by passing the target type first (the
`parse(T, x)` idiom). The format is inferred from the file unless `from` is
given: `.dss` is OpenDSS, a `.json` with the ENGINEERING `data_model` key is
PMD, otherwise BMOPF JSON. `from` tokens: `"dss"`, `"pmd"`, `"bmopf"`. Read
parse warnings with [`warnings`](@ref)`(net)`. Needs `--features dist`; see
[`dist_available`](@ref).
"""
function parse_file(::Type{MulticonductorNetwork}, path::AbstractString; from=nothing)
    h = _dist_parse_handle(path; from=from)
    return MulticonductorNetwork(h)
end

"""
    parse_str(MulticonductorNetwork, text, format) -> MulticonductorNetwork

Parse in-memory distribution case `text` of the named `format` (`"dss"`,
`"pmd"`, or `"bmopf"`; required, there is no path to infer from) — the explicit
form of the format-routed [`parse_str`](@ref)`(text, format)`. An OpenDSS
`Redirect`/`Compile` resolves against the current working directory.
"""
function parse_str(::Type{MulticonductorNetwork}, text::AbstractString, format::AbstractString)
    h = _dist_parse_handle_str(text, format)
    return MulticonductorNetwork(h)
end

"""
    from_json(MulticonductorNetwork, text) -> MulticonductorNetwork

Rebuild a live [`MulticonductorNetwork`](@ref) from the model JSON its `data`
payload serializes to (`pio_dist_to_json` / `JSON3.write(net.data)`, the same
object a `.pio.json` package carries under `model.multiconductor_network`) —
the distribution sibling of [`from_json`](@ref)`(text)`. The rebuilt handle
retains no source text, so a same format write is a fresh serialization.
Needs powerio-capi v0.7 built `--features dist`.
"""
function from_json(::Type{MulticonductorNetwork}, text::AbstractString)
    lib = _lib()
    _ensure_dist_compatible(lib)
    _require_export("from_json(MulticonductorNetwork)", :pio_dist_from_json,
                    "powerio v0.7, `--features dist`", lib)
    _dist_network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = ccall(_library_symbol(lib, :pio_dist_from_json), Ptr{Cvoid},
                (Cstring, Ptr{UInt8}, Csize_t), String(text), err, length(err))
    ptr == C_NULL && error("PowerIO.from_json(MulticonductorNetwork): " * _cstr(err))
    return MulticonductorNetwork(MulticonductorNetworkHandle(ptr, lib))
end

# --- accessors -------------------------------------------------------------
#
# Pure functions of the materialized payload: they work on a handle-less
# `MulticonductorNetwork` too. String bus ids, SI units, radians — the payload
# conventions, not the balanced accessors' MATPOWER ones. Unexported, like the
# balanced accessor API.

n_buses(net::MulticonductorNetwork) = Int(_summary(net).counts.buses)

"Buses, in source order: string ids, ordered `terminals`, explicit `grounded` terminals."
buses(net::MulticonductorNetwork) = _mc_table(net, :buses)
"Lines (conductor-level), each with `terminal_map_from` / `terminal_map_to` and a `linecode`. Optional per-conductor `i_max` (A) and `s_max` (VA) override the linecode's ratings."
lines(net::MulticonductorNetwork) = _mc_table(net, :lines)
"Line codes: per-unit-length impedance and shunt matrices, row-major, SI. Optional `source` names the matrix provenance."
linecodes(net::MulticonductorNetwork) = _mc_table(net, :linecodes)
"Switches, with the same terminal maps as lines."
switches(net::MulticonductorNetwork) = _mc_table(net, :switches)
"Transformers: windings with terminal maps, connection kinds, and impedances."
transformers(net::MulticonductorNetwork) = _mc_table(net, :transformers)
"Loads, each with a `terminal_map` and a voltage model."
loads(net::MulticonductorNetwork) = _mc_table(net, :loads)
"Generators, each with a `terminal_map` and optional per-conductor `s_max` (VA) / `i_max` (A)."
generators(net::MulticonductorNetwork) = _mc_table(net, :generators)
"Inverter-based resources, each with a `terminal_map`. Empty unless the source case carries them."
ibrs(net::MulticonductorNetwork) = _mc_table(net, :ibrs)
"Control profiles attached to controllable elements. Empty unless the source case carries them."
control_profiles(net::MulticonductorNetwork) = _mc_table(net, :control_profiles)
"Shunts, each with a `terminal_map` and conductance/susceptance matrices."
shunts(net::MulticonductorNetwork) = _mc_table(net, :shunts)
"Rated capacitor banks (nameplate `q_rated` var, `v_nom` V). Empty when the case has none; `dist_capabilities().typed_capacitors` reports library support."
capacitors(net::MulticonductorNetwork) = _mc_table(net, :capacitors)
"Voltage sources, each with a `terminal_map` and per-terminal magnitude/angle."
sources(net::MulticonductorNetwork) = _mc_table(net, :sources)
"Elements the reader kept verbatim because they have no typed slot."
untyped(net::MulticonductorNetwork) = _mc_table(net, :untyped)

"""
    base_frequency(net::MulticonductorNetwork) -> Float64

The system frequency in Hz.
"""
base_frequency(net::MulticonductorNetwork) = _json_float(_summary(net).base_frequency)

"""
    network_name(net::MulticonductorNetwork) -> Union{String,Nothing}

The case name, or `nothing` when the source carries none (unlike the balanced
accessor, which always has one).
"""
function network_name(net::MulticonductorNetwork)
    name = _summary(net).name
    return name === nothing ? nothing : String(name)
end

"""
    source_format(net::MulticonductorNetwork) -> Union{String,Nothing}

The format the case was read from, as the payload spells it — note the
casing differs from the balanced accessor's PascalCase `SourceFormat` names —
or `nothing` for an in-memory model.
"""
function source_format(net::MulticonductorNetwork)
    source = _summary(net).source_format
    return source === nothing ? nothing : String(source)
end

"""
    warnings(net::MulticonductorNetwork) -> Vector{String}

The parse warnings — everything the reader could not represent or had to
assume. Read from the live handle (`pio_dist_warnings`) when there is one,
else from the payload's `warnings` field, so they survive a package round trip.

Each line reads `CODE: message`; see [`warnings(::BalancedNetwork)`](@ref) for
how to read one.
"""
function warnings(net::MulticonductorNetwork)
    h = getfield(net, :handle)
    if h !== nothing && h.ptr != C_NULL
        lib = getfield(h, :lib)
        _ensure_dist_compatible(lib)
        return GC.@preserve h _warnings_from((out, cap) -> ccall(_library_symbol(lib, :pio_dist_warnings), Csize_t,
                                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, out, cap))
    end
    return String[String(w) for w in net.data.warnings]
end

# --- serialize and convert --------------------------------------------------

"""
    to_format(net::MulticonductorNetwork, to) -> (text, warnings)

Serialize a [`MulticonductorNetwork`](@ref) to format `to` (`"dss"`, `"pmd"`, or
`"bmopf"`) — the distribution method of [`to_format`](@ref). Writing back to
the format the handle was parsed from echoes the source byte for byte; a
cross-format write reports every fidelity loss in `warnings`. A balanced target
is a directed error: lowering is explicit, through the package pass.
"""
function to_format(net::MulticonductorNetwork, to::AbstractString)
    _is_dist_format(to) || _cross_model_error("to_format")
    h = _live_dist_handle(net, "to_format")
    lib = getfield(h, :lib)
    _ensure_dist_compatible(lib)
    diagref = _diagref()
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_dist_to_format), Cstring,
                             (Ptr{Cvoid}, Cstring, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
                             h.ptr, String(to), diagref, err, length(err))
    s == C_NULL && error("PowerIO.to_format(MulticonductorNetwork): " * _cstr(err))
    text = _take_string(lib, s)
    return (text, _take_warnings(lib, diagref))
end

"""
    convert_file(MulticonductorNetwork, path, to; from=nothing) -> (text, warnings)

Convert distribution case `path` to format `to` (`"dss"`, `"pmd"`, `"bmopf"`)
in one shot — the explicit form of the format-routed [`convert_file`](@ref).
`from` overrides extension inference (see `parse_file(MulticonductorNetwork, ...)`).
Returns the converted text and the warnings (parse warnings plus the writer's
fidelity losses, since there is no handle to query).
"""
function convert_file(::Type{MulticonductorNetwork}, path::AbstractString, to::AbstractString; from=nothing)
    lib = _lib()
    _ensure_dist_compatible(lib)
    diagref = _diagref()
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : String(from)
    s = try
        ccall(_library_symbol(lib, :pio_dist_convert_file), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
              path, fromc, String(to), diagref, err, length(err))
    catch e
        _feature_call_error("convert_file", "pio_dist_convert_file", "dist", e)
    end
    s == C_NULL && error("PowerIO.convert_file(MulticonductorNetwork): " * _cstr(err))
    text = _take_string(lib, s)
    return (text, _take_warnings(lib, diagref))
end

"""
    convert_str(MulticonductorNetwork, text, to; from) -> (text, warnings)

Convert in-memory distribution case `text` of format `from` to format `to`
(both required; `"dss"`, `"pmd"`, `"bmopf"`). The string sibling of
`convert_file(MulticonductorNetwork, ...)`, taking `from` as a keyword the way
[`convert_str`](@ref)`(text, to; from)` does.
"""
function convert_str(::Type{MulticonductorNetwork}, text::AbstractString, to::AbstractString;
                     from::AbstractString)
    lib = _lib()
    _ensure_dist_compatible(lib)
    diagref = _diagref()
    err = zeros(UInt8, _ERRLEN)
    s = try
        ccall(_library_symbol(lib, :pio_dist_convert_str), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Ptr{UInt8}}, Ptr{UInt8}, Csize_t),
              String(text), String(from), String(to), diagref, err, length(err))
    catch e
        _feature_call_error("convert_str", "pio_dist_convert_str", "dist", e)
    end
    s == C_NULL && error("PowerIO.convert_str(MulticonductorNetwork): " * _cstr(err))
    out = _take_string(lib, s)
    return (out, _take_warnings(lib, diagref))
end
