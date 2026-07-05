# --- public surface -----------------------------------------------------

"""
    BalancedNetwork

An immutable view of a parsed case, materialized from the C ABI's JSON transport.
Raw MATPOWER units and 1-based bus ids, mirroring `powerio`'s `BalancedNetwork`: buses,
loads, shunts, branches, generators, storage, and hvdc tables plus `base_mva`,
`name`, and `source_format` (the format it was read from). For now the tables are
the parsed JSON (`net.data`).

A `BalancedNetwork` from [`parse_file`](@ref) also keeps its live Rust [`BalancedNetworkHandle`](@ref)
(`net.handle`), so the `to_*` transforms ([`to_normalized`](@ref), [`to_dense`](@ref),
[`to_matpower`](@ref), [`to_arrow`](@ref)) work straight off it. The handle's
finalizer frees the Rust case once the `BalancedNetwork` is unreachable. A `BalancedNetwork` constructed
from a bare `JSON3.Object` has `handle === nothing`; the accessors and [`to_json`](@ref) work
on it, but the handle-only transforms error.
"""
struct BalancedNetwork
    data::JSON3.Object
    handle::Union{BalancedNetworkHandle,Nothing}
end
BalancedNetwork(data::JSON3.Object) = BalancedNetwork(data, nothing)

# A one-line REPL summary. Uses only the JSON-backed accessors, so a handle-less
# `BalancedNetwork` (built by `from_json`) shows without needing the Rust library.
function Base.show(io::IO, net::BalancedNetwork)
    print(io, "BalancedNetwork{", source_format(net), "}: ", n_buses(net), " buses, ",
          n_branches(net), " branches, ", n_gens(net), " gens")
end

Base.@deprecate_binding Network BalancedNetwork

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
core parsers use (`pio_classify_str`), unless `from` is given. From an `io`
stream the `format` is required (there is no extension); parse in-memory text
by wrapping it, `parse_file(IOBuffer(text), "matpower")`.

Accepted format tokens (case-insensitive): `"matpower"`/`"m"`,
`"powermodels-json"`/`"powermodels"`/`"pm"`, `"egret-json"`/`"egret"`,
`"psse"`/`"raw"`, `"powerworld"`/`"aux"`, `"pslf"`/`"epc"`,
`"pandapower-json"`/`"pandapower"`, `"surge-json"`/`"surge"`,
`"pypsa-csv"`; distribution: `"dss"`/`"opendss"`, `"pmd"`/`"engineering"`,
`"bmopf"`.

The type-marker forms pin the model when the routed return type would be
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
            fam = _classify_family(read(path, String))
            fam === :distribution && return parse_file(MulticonductorNetwork, path)
            fam === :package && return from_package(read_package(path))
        end
    end
    h = _parse_handle(path; from=from)
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
end
function parse_file(io::IO, format::AbstractString)
    _is_dist_format(format) && return parse_str(MulticonductorNetwork, read(io, String), format)
    h = _parse_handle_str(read(io, String), format)
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
end
# Explicit transmission marker, symmetric with `parse_file(MulticonductorNetwork, ...)`:
# bypasses the format routing, so it reaches the balanced parser no matter the
# extension.
function parse_file(::Type{BalancedNetwork}, path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
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
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
end

"""
    from_json(text) -> BalancedNetwork

Rebuild a live [`BalancedNetwork`](@ref) from the JSON transport produced by
[`to_json`](@ref). The result has a Rust handle, so `to_*` transforms work on it.
"""
function from_json(text::AbstractString)
    h = _from_json_handle(text)
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
end

# The live Rust handle a BalancedNetwork-first transform needs; a manually constructed
# BalancedNetwork has none, and a finalized handle is non-`nothing` but null. Name the
# function that needs it.
function _live_handle(net::BalancedNetwork, fname::AbstractString)
    h = net.handle
    (h === nothing || h.ptr == C_NULL) && error(
        "PowerIO.$fname: this BalancedNetwork has no live network handle (produce it with parse_file, parse_str, or from_json).")
    return h
end

# Derive a normalized handle from a live one via `pio_normalize` (a read-only
# borrow of the source case, so the source handle stays valid). GC.@preserve:
# Julia frees an object after its last use, not at end of call, so without it a
# GC triggered between extracting `h.ptr` and the ccall could finalize `h` and
# hand the Rust side a freed pointer. Every helper that lowers a handle to a raw
# pointer carries the same guard.
const POWER_MODELS_ANGLE_BOUND_PAD = 1.0472

function _normalize_handle(h::BalancedNetworkHandle)
    lib = getfield(h, :lib)
    _network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_normalize), Ptr{Cvoid},
                               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    ptr == C_NULL && error("PowerIO.to_normalized: " * _cstr(err))
    return BalancedNetworkHandle(ptr, lib)
end

function _normalize_handle_with_options(h::BalancedNetworkHandle,
                                        clamp_angle_bounds::Bool,
                                        angle_bound_pad::Real)
    lib = getfield(h, :lib)
    _exports_symbol(:pio_normalize_with_options, lib) || error(
        "PowerIO.to_normalized_with_options: the C ABI at \"$lib\" does not export " *
        "pio_normalize_with_options. Rebuild powerio-capi from the matching PowerIO branch.")
    _network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_normalize_with_options), Ptr{Cvoid},
                               (Ptr{Cvoid}, Cint, Cdouble, Ptr{UInt8}, Csize_t),
                               h.ptr, clamp_angle_bounds ? Cint(1) : Cint(0),
                               Cdouble(angle_bound_pad), err, length(err))
    ptr == C_NULL && error("PowerIO.to_normalized_with_options: " * _cstr(err))
    return BalancedNetworkHandle(ptr, lib)
end

"""
    to_normalized(net::BalancedNetwork; clamp_angle_bounds=false, angle_bound_pad=nothing) -> BalancedNetwork

A computation-ready copy of `net`: per unit (powers ÷ `base_mva`), angles in
radians, transformer tap `0 → 1`, out-of-service and isolated elements dropped,
source bus ids preserved, and bus types inferred (a bus with a surviving generator
keeps `REF` if the source marked it so, else becomes `PV`; a generator-less bus
becomes `PQ`). `source_format` of the result is `"Normalized"`.

Needs `net`'s live Rust handle (from [`parse_file`](@ref)). Errors if `base_mva` is
not positive or no reference bus can be established. `clamp_angle_bounds=true`
also applies the PowerModels angle difference repair in the Rust normalize pass.
"""
function to_normalized(net::BalancedNetwork; clamp_angle_bounds::Bool=false,
                       angle_bound_pad::Union{Nothing,Real}=nothing)
    h = _live_handle(net, "to_normalized")
    hn = if clamp_angle_bounds || angle_bound_pad !== nothing
        pad = angle_bound_pad === nothing ? POWER_MODELS_ANGLE_BOUND_PAD : angle_bound_pad
        _normalize_handle_with_options(h, clamp_angle_bounds, pad)
    else
        _normalize_handle(h)
    end
    return BalancedNetwork(JSON3.read(_to_json(hn)), hn)
end

"""
    to_normalized_with_options(net::BalancedNetwork; clamp_angle_bounds=false, angle_bound_pad=nothing)

Compatibility spelling for [`to_normalized`](@ref) with explicit normalize
options.
"""
to_normalized_with_options(net::BalancedNetwork; clamp_angle_bounds::Bool=false,
                           angle_bound_pad::Union{Nothing,Real}=nothing) =
    to_normalized(net; clamp_angle_bounds=clamp_angle_bounds,
                  angle_bound_pad=angle_bound_pad)

"""
    to_json(net::BalancedNetwork) -> String

Serialize `net` to the C ABI's JSON transport, the same text [`from_json`](@ref)
reads back. Uses the live handle when present, else the cached `net.data`.
"""
function to_json(net::BalancedNetwork)
    h = net.handle
    # A finalized handle (explicit `finalize(net.handle)`) is non-`nothing` but
    # null; the cached-data fallback covers it like the handleless case.
    return (h === nothing || h.ptr == C_NULL) ? JSON3.write(net.data) : _to_json(h)
end

function _format_from_handle(h::BalancedNetworkHandle, to::AbstractString, what::AbstractString)
    lib = getfield(h, :lib)
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_to_format), Cstring,
                             (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                             h.ptr, String(to), warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.to_format: " * _cstr(err) * " ($what)")
    text = unsafe_string(s)
    ccall(_library_symbol(lib, :pio_string_free), Cvoid, (Cstring,), s)
    return (text, _warn_lines(warnbuf; capped=true))
end

# `matpower` flows through the one string-keyed writer like every other format
# (v4 retired the per-format `pio_to_matpower`); a byte-exact MATPOWER round trip
# warns about nothing, so drop the warnings and return the text alone.
"""
    to_matpower(net::BalancedNetwork) -> String

Serialize `net` to MATPOWER `.m` text, byte exact when the input was MATPOWER. For a
file in one shot use [`convert_file`](@ref)`(path, "matpower")`.
"""
to_matpower(net::BalancedNetwork) =
    first(_format_from_handle(_live_handle(net, "to_matpower"), "matpower", repr(network_name(net))))

"""
    to_format(net::BalancedNetwork, to) -> (text, warnings)
    to_format(net::MulticonductorNetwork, to) -> (text, warnings)

Serialize a parsed network to format `to` without reparsing the input file.
Returns the target text and any fidelity warnings. Dispatches on the handle type,
so a [`MulticonductorNetwork`](@ref) writes the distribution formats.
"""
to_format(net::BalancedNetwork, to::AbstractString) =
    _format_from_handle(_live_handle(net, "to_format"), to, repr(network_name(net)))

"""
    warnings(net::BalancedNetwork) -> Vector{String}
    warnings(net::MulticonductorNetwork) -> Vector{String}

The fidelity warnings retained on a live handle (`pio_warnings`) — what the reader
could not represent or had to assume. Empty for a handle-less [`BalancedNetwork`](@ref).
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
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    # v4 argument order is (path, from, to), matching pio_to_format / pio_parse_str.
    fromc = from === nothing ? C_NULL : String(from)
    s = ccall(_library_symbol(lib, :pio_convert_file), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              path, fromc, to, warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.convert_file: " * _cstr(err))
    text = unsafe_string(s)
    ccall(_library_symbol(lib, :pio_string_free), Cvoid, (Cstring,), s)
    return (text, _warn_lines(warnbuf; capped=true))
end
# Explicit transmission marker, symmetric with `convert_file(MulticonductorNetwork, ...)`.
convert_file(::Type{BalancedNetwork}, path::AbstractString, to::AbstractString; from=nothing) =
    convert_file(path, to; from=from)

"""
    convert_str(text, to; from) -> (text, warnings)
    convert_str(MulticonductorNetwork, text, to, from) -> (text, warnings)

Convert in-memory case `text` to format `to` — the string sibling of
[`convert_file`](@ref) (`pio_convert_str`). `from` is required for a transmission
case (there is no path to infer from): the source format token. Pass
[`MulticonductorNetwork`](@ref) first for a distribution case.
"""
function convert_str(text::AbstractString, to::AbstractString; from::AbstractString)
    dist_to = _is_dist_format(to)
    dist_from = _is_dist_format(from)
    dist_to && dist_from && return convert_str(MulticonductorNetwork, text, to, from)
    (dist_to || dist_from) && _cross_model_error("convert_str")
    lib = _lib()
    _ensure_compatible(lib)
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    # v4 argument order is (text, from, to), matching pio_convert_file.
    s = ccall(_library_symbol(lib, :pio_convert_str), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              String(text), String(from), to, warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.convert_str: " * _cstr(err))
    out = unsafe_string(s)
    ccall(_library_symbol(lib, :pio_string_free), Cvoid, (Cstring,), s)
    return (out, _warn_lines(warnbuf; capped=true))
end

"""
    write_pypsa_csv_folder(net::BalancedNetwork, out_dir) -> (out_dir, warnings)

Write `net` as a PyPSA CSV folder under `out_dir` (created if absent) — the
directory-shaped inverse of `parse_file(out_dir; from="pypsa-csv")`, where the
other writers (`to_format`, `convert_file`) emit a single text document. Returns
the output directory and any fidelity warnings the writer reports for fields the
PyPSA static-network CSV schema can't carry. Needs `net`'s live Rust handle
(from [`parse_file`](@ref)).
"""
function write_pypsa_csv_folder(net::BalancedNetwork, out_dir::AbstractString)
    h = _live_handle(net, "write_pypsa_csv_folder")
    lib = getfield(h, :lib)
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    # `pio_write_dir` is the generic directory writer; `pypsa-csv` is the one such
    # format today. Fallible `int` return (0 = success), the warnbuf/errbuf
    # convention of `pio_to_format`; the handle is preserved across the ccall.
    rc = GC.@preserve h ccall(_library_symbol(lib, :pio_write_dir), Int32,
                              (Ptr{Cvoid}, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                              h.ptr, "pypsa-csv", String(out_dir), warnbuf, length(warnbuf), err, length(err))
    rc == 0 || error("PowerIO.write_pypsa_csv_folder: " * _cstr(err))
    return (String(out_dir), _warn_lines(warnbuf; capped=true))
end
