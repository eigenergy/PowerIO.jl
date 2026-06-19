# Multiconductor distribution surface over the C ABI (`pio_dist_*`, powerio-capi
# built `--features dist`).
#
# Transmission cases (balanced positive sequence) flow through `Network` and the
# `pio_*` functions; multiconductor unbalanced cases are a different model and
# ride their own `PioDistNetwork` handle, parsed from and written to OpenDSS
# (`"dss"`), PowerModelsDistribution ENGINEERING JSON (`"pmd"`), and the IEEE
# BMOPF Taskforce JSON (`"bmopf"`). The surface is parse / convert / serialize
# only — distribution data has no dense-extractor contract; rich structure rides
# the format JSON payloads, which carry their own `meta.version`.
#
# EXPERIMENTAL: the `pio_dist_*` signatures are frozen under `PIO_ABI_VERSION` 4,
# but the BMOPF schema (v0.0.1) and the JSON payloads may still evolve; pin a
# schema vintage from the payload, not from the ABI version. The functions ship
# only with the dist feature (on by default in the released binaries);
# `dist_available()` probes the symbol, the mirror of `arrow_available`.

# `pio_dist_network_free`, memoized per resolved path — the `_network_free_fn`
# story for distribution handles (a `set_library!` swap must not free across
# allocators; the pinned dlopen handle keeps the pointer valid for live finalizers).
const _DIST_FREE_FN = Ref{Ptr{Cvoid}}(C_NULL)
const _DIST_FREE_FN_LIB = Ref{String}("")
function _dist_network_free_fn()
    lib = _lib()
    if _DIST_FREE_FN[] == C_NULL || _DIST_FREE_FN_LIB[] != lib
        _DIST_FREE_FN[] = Libdl.dlsym(Libdl.dlopen(lib), :pio_dist_network_free)
        _DIST_FREE_FN_LIB[] = lib
    end
    return _DIST_FREE_FN[]
end

"""
    DistNetwork

Opaque handle to a parsed multiconductor distribution case inside the Rust core,
the distribution sibling of [`NetworkHandle`](@ref). Freed by its finalizer; you
get one from [`dist_parse_file`](@ref) / [`dist_parse_str`](@ref) and serialize it
with [`dist_to_format`](@ref). EXPERIMENTAL; see the `src/dist.jl` note.
"""
mutable struct DistNetwork
    ptr::Ptr{Cvoid}
    function DistNetwork(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("PowerIO: null distribution network handle")
        # Resolve the free fn before `new`: a failed lookup must not strand a
        # handle with no finalizer attached.
        free = _dist_network_free_fn()
        h = new(ptr)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(free, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

Base.show(io::IO, net::DistNetwork) =
    print(io, "DistNetwork(", net.ptr == C_NULL ? "freed" : "live", ")")

"""
    dist_available() -> Bool

True if the resolved C library exports `pio_dist_parse_file` (built `--features
dist`, on by default in the released binaries).
"""
dist_available() = _exports_symbol(:pio_dist_parse_file)

"""
    dist_parse_file(path; from=nothing) -> DistNetwork

Parse a distribution case file into a [`DistNetwork`](@ref). The format is inferred
from the file unless `from` is given: `.dss` is OpenDSS, a `.json` with the
ENGINEERING `data_model` key is PMD, otherwise BMOPF JSON. Accepted `from` tokens:
`"dss"`, `"pmd"`, `"bmopf"`. Retrieve parse warnings with [`dist_warnings`](@ref).
Needs powerio-capi built `--features dist`; see [`dist_available`](@ref).
"""
function dist_parse_file(path::AbstractString; from=nothing)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : String(from)
    ptr = try
        ccall((:pio_dist_parse_file, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              path, fromc, err, length(err))
    catch e
        _feature_call_error("dist_parse_file", "pio_dist_parse_file", "dist", e)
    end
    ptr == C_NULL && error("PowerIO.dist_parse_file: " * _cstr(err))
    return DistNetwork(ptr)
end

"""
    dist_parse_str(text, format) -> DistNetwork

Parse in-memory distribution case `text` of the named `format` (`"dss"`, `"pmd"`,
or `"bmopf"`; required, there is no path to infer from) into a [`DistNetwork`](@ref).
An OpenDSS `Redirect`/`Compile` resolves against the current working directory.
"""
function dist_parse_str(text::AbstractString, format::AbstractString)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_dist_parse_str, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), String(format), err, length(err))
    catch e
        _feature_call_error("dist_parse_str", "pio_dist_parse_str", "dist", e)
    end
    ptr == C_NULL && error("PowerIO.dist_parse_str: " * _cstr(err))
    return DistNetwork(ptr)
end

"""
    dist_warnings(net::DistNetwork) -> Vector{String}

The fidelity warnings retained on a [`DistNetwork`](@ref) handle — everything the
reader could not represent or had to assume — over `pio_dist_warnings`.
"""
dist_warnings(net::DistNetwork) =
    GC.@preserve net _warnings_from((out, cap) -> ccall((:pio_dist_warnings, _lib()), Csize_t,
                                    (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), net.ptr, out, cap))

"""
    dist_to_format(net::DistNetwork, to) -> (text, warnings)

Serialize a [`DistNetwork`](@ref) to format `to` (`"dss"`, `"pmd"`, or `"bmopf"`).
Writing back to the format the handle was parsed from echoes the source byte for
byte; a cross-format write reports every fidelity loss in `warnings`.
"""
function dist_to_format(net::DistNetwork, to::AbstractString)
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve net ccall((:pio_dist_to_format, _lib()), Cstring,
                               (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                               net.ptr, String(to), warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.dist_to_format: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return (text, _warn_lines(warnbuf; capped=true))
end

"""
    dist_convert_file(path, to; from=nothing) -> (text, warnings)

Convert distribution case `path` to format `to` (`"dss"`, `"pmd"`, `"bmopf"`) in
one shot, without keeping a handle. `from` overrides extension inference (see
[`dist_parse_file`](@ref)). Returns the converted text and the warnings (parse
warnings plus the writer's fidelity losses, since there is no handle to query).
"""
function dist_convert_file(path::AbstractString, to::AbstractString; from=nothing)
    _ensure_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : String(from)
    # NOTE: the dist convert argument order is (path, to, from) — target before
    # source — the opposite of the transmission `convert_file` (path, from, to).
    s = try
        ccall((:pio_dist_convert_file, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              path, to, fromc, warnbuf, length(warnbuf), err, length(err))
    catch e
        _feature_call_error("dist_convert_file", "pio_dist_convert_file", "dist", e)
    end
    s == C_NULL && error("PowerIO.dist_convert_file: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return (text, _warn_lines(warnbuf; capped=true))
end

"""
    dist_convert_str(text, to, from) -> (text, warnings)

Convert in-memory distribution case `text` of format `from` to format `to` (both
required; `"dss"`, `"pmd"`, `"bmopf"`). The string sibling of
[`dist_convert_file`](@ref); the argument order is input, target, source.
"""
function dist_convert_str(text::AbstractString, to::AbstractString, from::AbstractString)
    _ensure_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = try
        ccall((:pio_dist_convert_str, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              String(text), String(to), String(from), warnbuf, length(warnbuf), err, length(err))
    catch e
        _feature_call_error("dist_convert_str", "pio_dist_convert_str", "dist", e)
    end
    s == C_NULL && error("PowerIO.dist_convert_str: " * _cstr(err))
    out = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return (out, _warn_lines(warnbuf; capped=true))
end
