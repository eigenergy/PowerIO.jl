"""
    PowerIO

Julia bindings for the PowerIO Rust core: parse MATPOWER / PSS/E / PowerWorld /
PowerModels JSON case files, convert losslessly between them, and materialize an
immutable `Network` — all through the `powerio-capi` C ABI.

This is the thin Julia↔C layer. It holds an opaque case handle, calls
`pio_to_json` once, and parses the result with JSON3, so every accessor and every
ecosystem bridge is then pure Julia.

Status: scaffold. During development the C library is wired through a configurable
path (see [`set_library!`](@ref)); for the public release it ships as a self-hosted,
lazy artifact (`Artifacts.toml`), so users get the binary with no Rust toolchain. A
Yggdrasil `PowerIO_jll` is a later, non-blocking swap. See the README for the
milestone plan.
"""
module PowerIO

using JSON3
using LazyArtifacts
import Libdl

export Network, parse_case, convert_case, write_matpower

# --- library resolution -------------------------------------------------
#
# Resolution order: an explicit dev override (`POWERIO_CAPI` / `set_library!`)
# first, then the bundled `powerio_capi` artifact (the registered-release path),
# then a plain `libpowerio_capi` on the loader path. The artifact lookup is lazy
# and guarded, so a not-yet-populated `Artifacts.toml` (the binary isn't released
# yet) degrades to the loader-path fallback instead of breaking module load.
#
# Once a Yggdrasil `PowerIO_jll` is registered (issue #1, non-blocking) this whole
# block becomes `using PowerIO_jll` and `_lib() = PowerIO_jll.libpowerio_capi`.

const _LIBRARY = Ref{String}("")   # explicit dev override; "" means unset
const _RESOLVED = Ref{String}("")  # memoized non-override resolution (artifact/loader path)

function __init__()
    # Only the explicit override is read at init; the artifact/loader-path
    # fallback is resolved (and memoized) lazily in `_lib()`.
    _LIBRARY[] = get(ENV, "POWERIO_CAPI", "")
end

"""
    set_library!(path)

Point PowerIO at a locally built `libpowerio_capi` (`cargo build -p powerio-capi
--release` in the PowerIO Rust tree → `target/release/libpowerio_capi.{dylib,so}`).
A development override that wins over the bundled artifact.
"""
set_library!(path::AbstractString) = (_LIBRARY[] = String(path))

function _lib()
    isempty(_LIBRARY[]) || return _LIBRARY[]
    isempty(_RESOLVED[]) || return _RESOLVED[]
    return _RESOLVED[] = _artifact_lib()  # resolve once; bounds a failed lazy fetch to one attempt
end

# Resolve the bundled `powerio_capi` artifact. Until `Artifacts.toml` carries a
# `powerio_capi` entry for this platform (filled in after the BinaryBuilder
# release; see `gen/build_tarballs.jl`), fall back to a plain `libpowerio_capi` on
# the loader path so a local build still resolves.
function _artifact_lib()
    try
        return joinpath(artifact"powerio_capi", "lib", "libpowerio_capi.$(Libdl.dlext)")
    catch
        return "libpowerio_capi"
    end
end

"""
    library_available() -> Bool

True if the C ABI library resolves and exposes the ABI (probes `pio_n_buses`).
Tests that need the library skip when this is false.
"""
function library_available()
    try
        ccall((:pio_n_buses, _lib()), Csize_t, (Ptr{Cvoid},), C_NULL)
        return true
    catch
        return false
    end
end

const _ERRLEN = 512

# --- handle layer -------------------------------------------------------

"""
    CaseHandle

Opaque handle to a parsed case inside the Rust core. Freed by its finalizer; you
normally go straight to [`parse_case`](@ref), which returns a [`Network`].
"""
mutable struct CaseHandle
    ptr::Ptr{Cvoid}
    function CaseHandle(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("PowerIO: null case handle")
        h = new(ptr)
        finalizer(h) do x
            x.ptr == C_NULL || ccall((:pio_case_free, _lib()), Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

function _parse_handle(path::AbstractString)
    err = zeros(UInt8, _ERRLEN)
    ptr = ccall((:pio_parse, _lib()), Ptr{Cvoid},
                (Cstring, Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                path, C_NULL, err, length(err))
    ptr == C_NULL && error("PowerIO.parse_case: " * _cstr(err))
    return CaseHandle(ptr)
end

_cstr(buf::Vector{UInt8}) = unsafe_string(pointer(buf))

function _to_json(h::CaseHandle)
    err = zeros(UInt8, _ERRLEN)
    s = ccall((:pio_to_json, _lib()), Cstring, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
              h.ptr, err, length(err))
    s == C_NULL && error("PowerIO: to_json failed: " * _cstr(err))
    json = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return json
end

# --- public surface -----------------------------------------------------

"""
    Network

An immutable view of a parsed case, materialized from the C ABI's JSON transport.
Raw MATPOWER units and 1-based bus ids, mirroring `powerio`'s `Network`. For now
the tables are the parsed JSON (`net.data`); the fully typed struct mirroring
`powerio/src/network.rs` is M2 (see issues).
"""
struct Network
    data::JSON3.Object
end

"""
    parse_case(path) -> Network

Parse a case file (format inferred from the extension) into a [`Network`].
"""
function parse_case(path::AbstractString)
    h = _parse_handle(path)
    net = Network(JSON3.read(_to_json(h)))
    return net
end

"""
    write_matpower(path) -> String

Parse `path` and serialize it back to MATPOWER `.m` text — byte-exact when the
input was MATPOWER.
"""
function write_matpower(path::AbstractString)
    h = _parse_handle(path)
    s = ccall((:pio_write_matpower, _lib()), Cstring, (Ptr{Cvoid},), h.ptr)
    s == C_NULL && error("PowerIO.write_matpower failed")
    out = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return out
end

"""
    convert_case(path, to; from=nothing) -> (text, warnings)

Convert `path` to format `to` (`"matpower"`, `"powermodels-json"`, `"psse"`,
`"powerworld"`, `"egret-json"`). `warnings` lists anything the target can't
represent.
"""
function convert_case(path::AbstractString, to::AbstractString; from=nothing)
    warn = zeros(UInt8, _ERRLEN)
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : Base.unsafe_convert(Cstring, String(from))
    s = ccall((:pio_convert, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              path, to, fromc, warn, length(warn), err, length(err))
    s == C_NULL && error("PowerIO.convert_case: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    warnings = filter(!isempty, split(_cstr(warn), '\n'))
    return (text, warnings)
end

# --- accessor surface ---------------------------------------------------
#
# The v0.0.1 surface bridges read: the parsed element tables plus a few scalars.
# Element field names mirror the Rust `Network` (powerio/src/network.rs) and are
# the stable contract — raw MATPOWER units (MW/MVAr, degrees), 1-based bus ids,
# out-of-service elements retained, so a consumer normalizes as it sees fit:
#
#   bus:    id, kind ∈ {"PQ","PV","REF","ISOLATED"}, vm, va (deg), base_kv,
#           vmax, vmin, area, zone, name, extras
#   gen:    bus, pg, qg, pmax, pmin, qmax, qmin, vg, mbase, in_service,
#           cost (`nothing`, or {model, startup, shutdown, ncost, coeffs}), caps
#   branch: from, to, r, x, b, rate_a, rate_b, rate_c, tap, shift (deg),
#           in_service, angmin (deg), angmax (deg), extras
#   load:   bus, p (MW), q (MVAr), in_service, extras
#   shunt:  bus, g, b, in_service, extras
#
# The fully typed struct mirroring `network.rs` and the dense-extraction fast path
# are M2 (issue #2); these views are enough for the ecosystem bridges.

n_buses(net::Network) = length(net.data.buses)
n_branches(net::Network) = length(net.data.branches)
base_mva(net::Network) = Float64(net.data.base_mva)

"""
    network_name(net) -> String

The case name carried through from the source file.
"""
network_name(net::Network) = String(net.data.name)

"Buses, in source order (1-based ids preserved). See the accessor-surface note."
buses(net::Network) = net.data.buses
"Generators, one per machine (`bus` repeats when a bus has several)."
generators(net::Network) = net.data.generators
"Branches (lines and transformers), in source order."
branches(net::Network) = net.data.branches
"First-class loads (PSS/E and PowerModels keep several per bus; MATPOWER splits its bus row)."
loads(net::Network) = net.data.loads
"First-class bus shunts."
shunts(net::Network) = net.data.shunts

"""
    bus_type_code(kind) -> Int

Map the canonical bus-type string (`"PQ"`, `"PV"`, `"REF"`, `"ISOLATED"`) to the
MATPOWER code (1, 2, 3, 4). The string set matches `BusType::as_str` in the Rust
core, so the two can't drift.
"""
function bus_type_code(kind::AbstractString)
    kind == "PQ"       && return 1
    kind == "PV"       && return 2
    kind == "REF"      && return 3
    kind == "ISOLATED" && return 4
    throw(ArgumentError("PowerIO: unknown bus type $(repr(kind))"))
end

end # module
