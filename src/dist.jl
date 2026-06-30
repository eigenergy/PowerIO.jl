# Multiconductor distribution surface over the C ABI (`pio_dist_*`, powerio-capi
# built `--features dist`).
#
# Transmission cases (balanced positive sequence) flow through `BalancedNetwork` and
# multiconductor unbalanced cases through `MulticonductorNetwork` — a different model on its
# own handle, parsed from and written to OpenDSS (`"dss"`), PowerModelsDistribution
# ENGINEERING JSON (`"pmd"`), and the IEEE BMOPF Taskforce JSON (`"bmopf"`). The
# two share the verbs rather than prefixing: `to_format` / `warnings` dispatch on
# the handle type, and the entry points that build a handle from a path or string
# take the target type first, the `parse(T, x)` idiom — `parse_file(MulticonductorNetwork,
# path)` — since Julia dispatches on argument types, not the return type. The
# surface is parse / convert / serialize only; distribution data has no dense
# extractor surface; its structure rides the format JSON payloads.
#
# EXPERIMENTAL: the `pio_dist_*` signatures have their own `PIO_DIST_ABI_VERSION`
# starting with powerio v0.3.1. PowerIO.jl requires that version before calling
# distribution entry points. The functions ship only with the dist feature (on by
# default in the released binaries); `dist_available()` checks the symbol and the
# reported dist ABI version.

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
    MulticonductorNetwork

Opaque handle to a parsed multiconductor distribution case inside the Rust core,
the distribution sibling of [`NetworkHandle`](@ref). Build one with
`parse_file(MulticonductorNetwork, path)` / `parse_str(MulticonductorNetwork, text, format)` and
serialize it with [`to_format`](@ref)`(net, to)`. Freed by its finalizer.
EXPERIMENTAL; see the `src/dist.jl` note.
"""
mutable struct MulticonductorNetwork
    ptr::Ptr{Cvoid}
    function MulticonductorNetwork(ptr::Ptr{Cvoid})
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

Base.show(io::IO, net::MulticonductorNetwork) =
    print(io, "MulticonductorNetwork(", net.ptr == C_NULL ? "freed" : "live", ")")

Base.@deprecate_binding DistNetwork MulticonductorNetwork

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
        @debug "PowerIO: dist surface unavailable or incompatible" exception = (e, catch_backtrace())
        return false
    end
end

const PIO_DIST_ABI_VERSION = UInt32(1)

"""
    dist_abi_version() -> UInt32

The distribution C ABI version reported by `pio_dist_abi_version()`. Compared
against `PIO_DIST_ABI_VERSION`, the distribution ABI this binding targets.
"""
function dist_abi_version()
    _ensure_compatible()
    return ccall((:pio_dist_abi_version, _lib()), UInt32, ())
end

function _ensure_dist_compatible()
    _ensure_compatible()
    got = try
        dist_abi_version()
    catch e
        error("PowerIO: the C ABI at \"$(_lib())\" has no pio_dist_abi_version; " *
              "use powerio-capi v0.3.1 built with `--features dist`. Underlying: $e")
    end
    got == PIO_DIST_ABI_VERSION || error(
        "PowerIO: distribution C ABI version mismatch: the library reports dist ABI $got, " *
        "this PowerIO.jl targets dist ABI $(PIO_DIST_ABI_VERSION). Update the powerio-capi " *
        "artifact or local library.")
    return
end

"""
    parse_file(MulticonductorNetwork, path; from=nothing) -> MulticonductorNetwork

Parse a distribution case file into a [`MulticonductorNetwork`](@ref) — the distribution
overload of [`parse_file`](@ref), selected by passing the target type first (the
`parse(T, x)` idiom). The format is inferred from the file unless `from` is given:
`.dss` is OpenDSS, a `.json` with the ENGINEERING `data_model` key is PMD,
otherwise BMOPF JSON. `from` tokens: `"dss"`, `"pmd"`, `"bmopf"`. Read parse
warnings with [`warnings`](@ref)`(net)`. Needs `--features dist`; see
[`dist_available`](@ref).
"""
function parse_file(::Type{MulticonductorNetwork}, path::AbstractString; from=nothing)
    _ensure_dist_compatible()
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : String(from)
    ptr = try
        ccall((:pio_dist_parse_file, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              path, fromc, err, length(err))
    catch e
        _feature_call_error("parse_file", "pio_dist_parse_file", "dist", e)
    end
    ptr == C_NULL && error("PowerIO.parse_file(MulticonductorNetwork): " * _cstr(err))
    return MulticonductorNetwork(ptr)
end

"""
    parse_str(MulticonductorNetwork, text, format) -> MulticonductorNetwork

Parse in-memory distribution case `text` of the named `format` (`"dss"`, `"pmd"`,
or `"bmopf"`; required, there is no path to infer from) into a [`MulticonductorNetwork`](@ref).
An OpenDSS `Redirect`/`Compile` resolves against the current working directory.
"""
function parse_str(::Type{MulticonductorNetwork}, text::AbstractString, format::AbstractString)
    _ensure_dist_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_dist_parse_str, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), String(format), err, length(err))
    catch e
        _feature_call_error("parse_str", "pio_dist_parse_str", "dist", e)
    end
    ptr == C_NULL && error("PowerIO.parse_str(MulticonductorNetwork): " * _cstr(err))
    return MulticonductorNetwork(ptr)
end

"""
    warnings(net::MulticonductorNetwork) -> Vector{String}

The fidelity warnings retained on a [`MulticonductorNetwork`](@ref) handle — everything the
reader could not represent or had to assume — over `pio_dist_warnings`.
"""
function warnings(net::MulticonductorNetwork)
    _ensure_dist_compatible()
    GC.@preserve net _warnings_from((out, cap) -> ccall((:pio_dist_warnings, _lib()), Csize_t,
                                    (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), net.ptr, out, cap))
end

"""
    to_format(net::MulticonductorNetwork, to) -> (text, warnings)

Serialize a [`MulticonductorNetwork`](@ref) to format `to` (`"dss"`, `"pmd"`, or `"bmopf"`)
— the distribution method of [`to_format`](@ref). Writing back to the format the
handle was parsed from echoes the source byte for byte; a cross-format write
reports every fidelity loss in `warnings`.
"""
function to_format(net::MulticonductorNetwork, to::AbstractString)
    _ensure_dist_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve net ccall((:pio_dist_to_format, _lib()), Cstring,
                               (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                               net.ptr, String(to), warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.to_format(MulticonductorNetwork): " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return (text, _warn_lines(warnbuf; capped=true))
end

"""
    convert_file(MulticonductorNetwork, path, to; from=nothing) -> (text, warnings)

Convert distribution case `path` to format `to` (`"dss"`, `"pmd"`, `"bmopf"`) in
one shot — the distribution overload of [`convert_file`](@ref), selected by the
leading type. `from` overrides extension inference (see
`parse_file(MulticonductorNetwork, ...)`). Returns the converted text and the warnings
(parse warnings plus the writer's fidelity losses, since there is no handle to
query).
"""
function convert_file(::Type{MulticonductorNetwork}, path::AbstractString, to::AbstractString; from=nothing)
    _ensure_dist_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    fromc = from === nothing ? C_NULL : String(from)
    s = try
        ccall((:pio_dist_convert_file, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              path, fromc, String(to), warnbuf, length(warnbuf), err, length(err))
    catch e
        _feature_call_error("convert_file", "pio_dist_convert_file", "dist", e)
    end
    s == C_NULL && error("PowerIO.convert_file(MulticonductorNetwork): " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return (text, _warn_lines(warnbuf; capped=true))
end

"""
    convert_str(MulticonductorNetwork, text, to, from) -> (text, warnings)

Convert in-memory distribution case `text` of format `from` to format `to` (both
required; `"dss"`, `"pmd"`, `"bmopf"`). The string sibling of
`convert_file(MulticonductorNetwork, ...)`.
"""
function convert_str(::Type{MulticonductorNetwork}, text::AbstractString, to::AbstractString,
                     from::AbstractString)
    _ensure_dist_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = try
        ccall((:pio_dist_convert_str, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              String(text), String(from), String(to), warnbuf, length(warnbuf), err, length(err))
    catch e
        _feature_call_error("convert_str", "pio_dist_convert_str", "dist", e)
    end
    s == C_NULL && error("PowerIO.convert_str(MulticonductorNetwork): " * _cstr(err))
    out = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return (out, _warn_lines(warnbuf; capped=true))
end
