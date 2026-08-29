# Multiconductor distribution API over the C ABI (`pio_dist_*`, powerio-capi
# built `--features dist`).
#
# Transmission cases (balanced positive sequence) flow through `BalancedNetwork`
# and multiconductor unbalanced cases through `MulticonductorNetwork` — a
# different model on its own handle, parsed from and written to OpenDSS
# (`"dss"`), PowerModelsDistribution ENGINEERING JSON (`"pmd"`), and the IEEE
# BMOPF Taskforce JSON (`"bmopf"`). The two share the verbs: the bare verbs
# route on the format (see `parse_file`, pinned explicitly with its `format`
# keyword), `convert_file` / `convert_str` keep their type marker forms
# (`convert_file(MulticonductorNetwork, path, to)`), and `to_format` /
# `warnings` dispatch on the network type.
#
# Like `BalancedNetwork`, a parsed `MulticonductorNetwork` keeps a live Rust
# handle and leaves the element tables (`net.data`) unmaterialized until first
# access. The tables come from `pio_multiconductor_network_to_json`: the materialized model JSON, the same
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

# `pio_multiconductor_network_release`, memoized per resolved path — the `_network_free_fn`
# story for distribution handles (a `set_library!` swap must not free across
# allocators; the pinned dlopen handle keeps the pointer valid for live finalizers).
function _dist_network_free_fn(lib::AbstractString=_lib())
    return _library_symbol(String(lib), :pio_multiconductor_network_release)
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

A parsed multiconductor distribution case. `parse_file` and `parse_bytes` keep a
live Rust handle and leave `net.data` empty until first table access. The first
`net.data` access reads the `pio-payload-multiconductor/1` JSON payload:
`buses`, `linecodes`, `lines`, `switches`, `transformers`, `loads`,
`generators`, `ibrs`, `control_profiles`, `shunts`, `capacitors`, `sources`,
`untyped`, plus `base_frequency`, `name`, `source_format`, and parse
`warnings`. The writer omits `ibrs`, `control_profiles`, and `capacitors`
when they are empty; the accessors read a missing one as an empty table.
String bus ids, ordered string terminal names, SI units, radians.

Build one with [`parse_file`](@ref)`("feeder.dss")` (the bare verb routes on
the format) or `parse_file(path; format="dss")` to pin the parser explicitly. A
`MulticonductorNetwork` constructed from a bare payload object has
`handle === nothing`; the accessors work on it, but the handle transforms
([`to_format`](@ref)) error. JSON carry with provenance is the stored module
([`write_json`](@ref) / [`parse_file`](@ref)); tools outside PowerIO read
`to_format(net, "bmopf")`.

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

# The payload's own warnings field: the rendered lines the model JSON
# carries, kept readable as `net.warnings` for payload round trips. Live
# findings are the module's `diagnostics`.
_mc_payload_warnings(net::MulticonductorNetwork) =
    String[String(w) for w in get(net.data, :warnings, String[])]

# One reader per scalar property; `getproperty` and `propertynames` both
# derive from this table, so the two surfaces cannot drift.
const _MC_SCALAR_READERS = (; name = network_name, source_format = source_format,
                            warnings = _mc_payload_warnings,
                            base_frequency = base_frequency)
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

True if the resolved C library carries the multiconductor value family
(built `--features dist`, on by default in the released binaries).
"""
function dist_available()
    library_available() || return false
    return _exports_symbol(:pio_module_multiconductor_network)
end

_dist_graph_available() =
    _exports_symbol(:pio_multiconductor_network_graph_json)


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
    "models. Lower explicitly: parse_file the case, lower_to_balanced the module, " *
    "and write the balanced result.")

# --- parse and materialize ------------------------------------------------



# Materialize the element tables of a live handle with `pio_multiconductor_network_to_json`,
# returning the model JSON a `.pio.json` document carries under
# `model.multiconductor_network`.
function _dist_data(h::MulticonductorNetworkHandle)
    lib = getfield(h, :lib)
    text = GC.@preserve h begin
        raw = _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_multiconductor_network_to_json), Cstring,
                  (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), h.ptr, err)
        end
        _take_string(lib, raw)
    end
    return JSON3.read(text)
end

function _summary(h::MulticonductorNetworkHandle)
    lib = getfield(h, :lib)
    text = GC.@preserve h begin
        raw = _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_multiconductor_network_summary_json), Cstring,
                  (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), h.ptr, err)
        end
        _take_string(lib, raw)
    end
    return JSON3.read(text)
end

function _summary_from_data(data::JSON3.Object, ::Type{MulticonductorNetwork})
    count_keys = (_MC_TABLE_NAMES..., :warnings)
    counts = NamedTuple{count_keys}(map(k -> _payload_len(data, k), count_keys))
    return JSON3.read(JSON3.write((;
        powerio_version = something(schema_versions().powerio_version, ""),
        name = _payload_value(data, :name, ""),
        source_format = _payload_value(data, :source_format, "in-memory"),
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
        "(produce it with parse_file or parse_bytes).")
    h.ptr == C_NULL && error(
        "PowerIO.$fname: this MulticonductorNetwork's handle was finalized; access the data " *
        "you need (e.g. net.data) before calling finalize(net.handle).")
    return h
end


"""
    from_json(MulticonductorNetwork, text) -> MulticonductorNetwork

Rebuild a live [`MulticonductorNetwork`](@ref) from the model JSON its `data`
payload serializes to (`pio_multiconductor_network_to_json` / `JSON3.write(net.data)`, the same
object a `.pio.json` package carries under `model.multiconductor_network`) —
the distribution sibling of [`from_json`](@ref)`(text)`. The rebuilt handle
retains no source text, so a same format write is a fresh serialization.
Needs powerio-capi v0.7 built `--features dist`.
"""
function from_json(::Type{MulticonductorNetwork}, text::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("from_json(MulticonductorNetwork)", :pio_multiconductor_network_from_json,
                    "powerio built `--features dist`", lib)
    _dist_network_free_fn(lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_multiconductor_network_from_json), Ptr{Cvoid},
              (Cstring, Ref{Ptr{Cvoid}}), String(text), err)
    end
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
"Rated capacitor banks (nameplate `q_rated` var, `v_nom` V). Empty when the case has none or the library predates the table."
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

The format the case was read from, as the payload spells it (the same
lowercase token convention as the balanced accessor since powerio 0.9), or
`nothing` for an in-memory model.
"""
function source_format(net::MulticonductorNetwork)
    source = _summary(net).source_format
    return source === nothing ? nothing : String(source)
end


# --- serialize and convert --------------------------------------------------

"""
    to_format(net::MulticonductorNetwork, to) -> (text, findings)

Serialize a [`MulticonductorNetwork`](@ref) to format `to` (`"dss"`, `"pmd"`, or
`"bmopf"`) — the distribution method of [`to_format`](@ref). Writing back to
the format the handle was parsed from echoes the source byte for byte; a
cross-format write reports every fidelity loss in the returned findings. A balanced target
is a directed error: lowering is explicit, through the package pass.
"""
function to_format(net::MulticonductorNetwork, to::AbstractString)
    _is_dist_format(to) || _cross_model_error("to_format")
    h = _live_dist_handle(net, "to_format")
    lib = getfield(h, :lib)
    module_ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_of_multiconductor_network), Ptr{Cvoid},
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
    return (text, _diagnostics_of(_ -> out_diagnostics[], lib))
end

"""
    convert_file(MulticonductorNetwork, path, to; from=nothing) -> (text, findings)

Convert distribution case `path` to format `to` (`"dss"`, `"pmd"`, `"bmopf"`)
in one shot — the explicit form of the format-routed [`convert_file`](@ref).
`from` overrides extension inference; [`parse_file`](@ref) pins the same way with its `format` keyword.
Returns the converted text and the findings (the reader's plus the writer's
fidelity losses, since there is no handle to query).
"""
function convert_file(::Type{MulticonductorNetwork}, path::AbstractString, to::AbstractString; from=nothing)
    lib = _lib()
    _ensure_compatible(lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    fromc = from === nothing ? C_NULL : String(from)
    s = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_convert_file), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Cvoid}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              path, fromc, String(to), C_NULL, out_diagnostics, err)
    end
    text = _take_string(lib, s)
    return (text, _diagnostics_of(_ -> out_diagnostics[], lib))
end

"""
    convert_str(MulticonductorNetwork, text, to; from) -> (text, findings)

Convert in-memory distribution case `text` of format `from` to format `to`
(both required; `"dss"`, `"pmd"`, `"bmopf"`). The string sibling of
`convert_file(MulticonductorNetwork, ...)`, taking `from` as a keyword the way
[`convert_str`](@ref)`(text, to; from)` does.
"""
function convert_str(::Type{MulticonductorNetwork}, text::AbstractString, to::AbstractString;
                     from::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    s = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_convert_str), Cstring,
              (Cstring, Cstring, Cstring, Ptr{Cvoid}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              String(text), String(from), String(to), C_NULL, out_diagnostics, err)
    end
    out = _take_string(lib, s)
    return (out, _diagnostics_of(_ -> out_diagnostics[], lib))
end
