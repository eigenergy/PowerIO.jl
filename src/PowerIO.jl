"""
    PowerIO

Julia bindings for the PowerIO Rust core: parse MATPOWER / PSS/E / PowerWorld /
PowerModels JSON case files, convert losslessly between them, and materialize an
immutable `Network` — all through the `powerio-capi` C ABI.

This is the thin Julia↔C layer. It holds an opaque case handle, calls
`pio_to_json` once, and parses the result with JSON3, so every accessor and every
ecosystem bridge is then pure Julia.

Status: scaffold. The C library is wired through a configurable path during
development (see [`set_library!`](@ref)); milestone M1 replaces that with a
registered `PowerIO_jll` built by Yggdrasil, so users get the binary with no
Rust toolchain. See the README for the milestone plan.
"""
module PowerIO

using JSON3

export Network, parse_case, convert_case, write_matpower

# --- library resolution -------------------------------------------------
#
# Until `PowerIO_jll` exists (M1), the C ABI library is found at runtime: from
# the `POWERIO_CAPI` environment variable, else a plain `libpowerio_capi` on the
# loader path. Once the jll is registered this whole block becomes
# `using PowerIO_jll` and `_lib() = PowerIO_jll.libpowerio_capi`.

const _LIBRARY = Ref{String}("")

function __init__()
    _LIBRARY[] = get(ENV, "POWERIO_CAPI", "libpowerio_capi")
end

"""
    set_library!(path)

Point PowerIO at a locally built `libpowerio_capi` (`cargo build -p powerio-capi
--release` in the PowerIO Rust tree → `target/release/libpowerio_capi.{dylib,so}`).
A development override until `PowerIO_jll` lands.
"""
set_library!(path::AbstractString) = (_LIBRARY[] = String(path))

_lib() = _LIBRARY[]

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

# Convenience accessors over the JSON view (a thin slice of the M2 struct API).
n_buses(net::Network) = length(net.data.buses)
n_branches(net::Network) = length(net.data.branches)
base_mva(net::Network) = Float64(net.data.base_mva)

end # module
