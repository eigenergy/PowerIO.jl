# --- library resolution -------------------------------------------------
#
# Resolution order: an explicit dev override (`POWERIO_CAPI` / `set_library!`)
# first, then the bundled `powerio_capi` artifact (the registered-release path),
# then a sibling `../powerio` checkout's `target/{release,debug}` build (zero-config
# tandem dev), then a plain `libpowerio_capi` on the loader path. The artifact lookup
# is lazy and guarded, so a not-yet-populated `Artifacts.toml` (the binary isn't
# released yet) degrades to the sibling/loader-path fallback instead of breaking
# module load.
#
# Once a `PowerIO_jll` is registered (issue #1, non-blocking) this whole block
# becomes `using PowerIO_jll` and `_lib() = PowerIO_jll.libpowerio_capi`.

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
function set_library!(path::AbstractString)
    _LIBRARY[] = String(path)
    _ABI_OK[] = false  # the new library must pass its own handshake
    return
end

function _lib()
    isempty(_LIBRARY[]) || return _LIBRARY[]
    isempty(_RESOLVED[]) || return _RESOLVED[]
    return _RESOLVED[] = _artifact_lib()  # resolve once; bounds a failed lazy fetch to one attempt
end

# Resolve the bundled `powerio_capi` artifact. Until `Artifacts.toml` carries a
# `powerio_capi` entry for this platform (filled by `gen/update_artifacts.jl` from
# a tagged powerio release; see docs/src/binary.md), fall back to a plain
# `libpowerio_capi` on the loader path so a local build still resolves.
#
# The subdir mirrors what `gen/build_tarballs.jl` installs: BinaryBuilder ships the
# Windows dll under `bin/`, the shared object under `lib/` everywhere else. This
# hardcoding is a stopgap; once the binary ships, the right form is to let the
# JLL/`Artifacts.toml` `LibraryProduct` resolve the dlopen path per platform.
function _artifact_lib()
    libsubdir = Sys.iswindows() ? "bin" : "lib"
    try
        return joinpath(artifact"powerio_capi", libsubdir, "libpowerio_capi.$(Libdl.dlext)")
    catch e
        # Expected while the artifact is unpublished. Once it ships, a corrupt or
        # platform-missing artifact also lands here, so leave a trace (JULIA_DEBUG=PowerIO)
        # rather than silently masking it; the loader-path fallback still keeps dev working.
        @debug "PowerIO: powerio_capi artifact did not resolve; trying a sibling powerio checkout, then loader-path libpowerio_capi" exception = (e, catch_backtrace())
        sib = _sibling_lib()
        isempty(sib) || return sib
        return "libpowerio_capi"
    end
end

# Dev convenience: when this package sits beside a `powerio` checkout (the usual
# layout for working on both at once), resolve the locally built cdylib straight
# from `../powerio/target/{release,debug}` — no `POWERIO_CAPI` and no `set_library!`
# after a plain `cargo build -p powerio-capi`. Release wins over debug; returns ""
# when no sibling build is present.
function _sibling_lib()
    base = joinpath(dirname(dirname(@__DIR__)), "powerio", "target")
    lib = "libpowerio_capi.$(Libdl.dlext)"
    for profile in ("release", "debug")
        cand = joinpath(base, profile, lib)
        isfile(cand) && return cand
    end
    return ""
end

# --- ABI version handshake ----------------------------------------------
#
# The C ABI carries an integer ABI version (`pio_abi_version`, added alongside the
# typed extractors). This binding targets exactly `PIO_ABI_VERSION`; bump the two in
# lockstep when an existing `pio_*` signature or the JSON transport schema changes.
# Checking it once at first use turns "library predates this binding" and "library is
# from an incompatible commit" into a clear error at the boundary, instead of a
# cryptic ccall fault (a wrong signature) or silently wrong numbers deep in a solver.

const PIO_ABI_VERSION = UInt32(4)
const _ABI_OK = Ref{Bool}(false)

"""
    abi_version() -> UInt32

The ABI version the resolved C library was built with (see `pio_abi_version`).
Compared against `PIO_ABI_VERSION`, the version this binding targets.
"""
abi_version() = ccall((:pio_abi_version, _lib()), UInt32, ())

"""
    library_version() -> String

The `powerio-capi` crate version string the resolved library reports (e.g.
`"0.3.1"`). Informational; [`abi_version`](@ref) is the compatibility check.
"""
function library_version()
    s = ccall((:pio_version, _lib()), Cstring, ())
    return s == C_NULL ? "" : unsafe_string(s)  # 'static in the library; do not free
end

# Verify the resolved library is ABI-compatible, once (memoized). Throws a directed
# error otherwise; every entry point that calls into the library runs this first.
function _ensure_compatible()
    _ABI_OK[] && return
    got = try
        abi_version()
    catch e
        error("PowerIO: the C ABI at \"$(_lib())\" has no pio_abi_version: it predates " *
              "the versioned ABI. Rebuild powerio-capi (`cargo build -p powerio-capi --release` " *
              "in a sibling powerio checkout). Underlying: $e")
    end
    got == PIO_ABI_VERSION || error(
        "PowerIO: C ABI version mismatch: the library reports ABI $got, this PowerIO.jl " *
        "targets ABI $(PIO_ABI_VERSION). Rebuild powerio-capi from a matching commit, or " *
        "update PowerIO.jl.")
    _ABI_OK[] = true
    return
end

"""
    library_available() -> Bool

True if the C ABI library resolves and is ABI compatible with this binding
(see [`abi_version`](@ref)).
"""
function library_available()
    try
        _ensure_compatible()
        return true
    catch e
        # Probe: false means "not usable here". The logged message distinguishes
        # "library absent", "predates the versioned ABI", and "ABI mismatch".
        @debug "PowerIO: library unavailable or incompatible" exception = (e, catch_backtrace())
        return false
    end
end

# Shared probe behind `arrow_available`/`gridfm_available`: true if the resolved
# library exports `sym` (the feature-gated entry points come and go with cargo
# features, not the ABI version).
function _exports_symbol(sym::Symbol)
    try
        handle = Libdl.dlopen(_lib())
        try
            return Libdl.dlsym(handle, sym; throw_error=false) !== nothing
        finally
            Libdl.dlclose(handle)
        end
    catch e
        @debug "PowerIO: $sym probe failed" exception = (e, catch_backtrace())
        return false
    end
end

# Classify in-memory JSON by the core's cross-domain markers
# (`pio_classify_str`): :transmission, :distribution, :package, :ambiguous, or
# :unknown. Older libraries lack the symbol; :unavailable keeps the caller on
# its pre-classify behavior (balanced inference and its errors).
function _classify_family(text::AbstractString)
    _exports_symbol(:pio_classify_str) || return :unavailable
    _ensure_compatible()
    buf = zeros(UInt8, 64)
    n = ccall((:pio_classify_str, _lib()), Csize_t,
              (Cstring, Ptr{UInt8}, Csize_t), String(text), buf, length(buf))
    n == 0 && return :unknown
    return Symbol(first(split(_cstr(buf), ':')))
end

const _ERRLEN = 512
# Per-call fidelity warnings (pio_to_format / pio_convert_file / pio_write_dir)
# can run long on a lossy conversion; give them headroom. Overflow truncates
# silently, so `_warn_lines(capped=true)` surfaces a fill near the cap.
const _WARNLEN = 4096

# --- handle layer -------------------------------------------------------

# The allocating library's `pio_network_free`, memoized per resolved path:
# resolving `_lib()` at finalization time would cross allocators after a
# `set_library!` swap. The un-dlclosed handle deliberately pins the library so
# the pointer stays valid for every outstanding finalizer.
const _FREE_FN = Ref{Ptr{Cvoid}}(C_NULL)
const _FREE_FN_LIB = Ref{String}("")
function _network_free_fn()
    lib = _lib()
    if _FREE_FN[] == C_NULL || _FREE_FN_LIB[] != lib
        _FREE_FN[] = Libdl.dlsym(Libdl.dlopen(lib), :pio_network_free)
        _FREE_FN_LIB[] = lib
    end
    return _FREE_FN[]
end

"""
    BalancedNetworkHandle

Opaque handle to a parsed network inside the Rust core. Freed by its finalizer;
you normally go straight to [`parse_file`](@ref), which returns a [`BalancedNetwork`].
"""
mutable struct BalancedNetworkHandle
    ptr::Ptr{Cvoid}
    function BalancedNetworkHandle(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("PowerIO: null network handle")
        # Resolve before `new`: a failed lookup must not strand a handle with
        # no finalizer attached.
        free = _network_free_fn()
        h = new(ptr)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(free, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

Base.@deprecate_binding NetworkHandle BalancedNetworkHandle

# Directed error for when the ccall itself fails to dispatch — a missing library or
# undefined symbol — instead of a raw ccall fault far from the resolution site.
_lib_call_error(e) = error(
    "PowerIO: could not call the C ABI at \"$(_lib())\": build it " *
    "(`cargo build -p powerio-capi --release` in a sibling powerio checkout) " *
    "or set POWERIO_CAPI / call `set_library!`. Underlying: $e")

# Sibling of `_lib_call_error` for the feature-gated entry points: the ccall threw
# because the resolved library lacks `sym`. Anything other than the missing
# symbol/library ErrorException (e.g. an ArgumentError from argument conversion)
# is not a toolchain problem — rethrow it untouched.
function _feature_call_error(fname::AbstractString, sym::AbstractString,
                             feature::AbstractString, e)
    e isa ErrorException || throw(e)
    error("PowerIO.$fname: could not call $sym: the C ABI at \"$(_lib())\" was " *
          "built without the $feature feature. Rebuild with " *
          "`cargo build -p powerio-capi --release --features $feature`. Underlying: $e")
end

function _parse_handle(path::AbstractString; from=nothing)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    fromc = from === nothing ? C_NULL : String(from)
    ptr = try
        ccall((:pio_parse_file, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              path, fromc, err, length(err))
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.parse_file: " * _cstr(err))
    return BalancedNetworkHandle(ptr)
end

# In-memory sibling of `_parse_handle`: parse `text` under an explicit `format`
# (no path, so no extension to infer from) via `pio_parse_str`.
function _parse_handle_str(text::AbstractString, format::AbstractString)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_parse_str, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), String(format), err, length(err))
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.parse_str: " * _cstr(err))
    return BalancedNetworkHandle(ptr)
end

# `from_json` rebuilds from the canonical `powerio-json` snapshot, the format
# `_to_json` writes; it is `pio_parse_str` under the `powerio-json` name (the v4
# ABI folded the old `pio_from_json` into the one string-keyed parser, validated
# on read). The distinct label keeps the error pointed at `from_json`.
function _from_json_handle(text::AbstractString)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_parse_str, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), "powerio-json", err, length(err))
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.from_json: " * _cstr(err))
    return BalancedNetworkHandle(ptr)
end

# `buf` must stay rooted across the unsafe_string read; without the preserve the
# compiler may drop the buffer after `pointer(buf)` and a GC mid-copy dangles.
_cstr(buf::Vector{UInt8}) = GC.@preserve buf unsafe_string(pointer(buf))

# Split a `\n`-joined warn buffer into owned Strings (a SubString would pin the
# whole buffer-sized parent). `capped`: the fixed-size per-call channel truncates
# silently on a UTF-8 boundary at the cap, so a fill within 4 bytes of it is the
# truncation signature — surface it rather than under-count fidelity warnings.
function _warn_lines(buf::Vector{UInt8}; capped::Bool=false)
    s = _cstr(buf)
    warns = String.(filter(!isempty, split(s, '\n')))
    capped && ncodeunits(s) >= length(buf) - 4 &&
        push!(warns, "... warning list truncated at $(length(buf)) bytes")
    return warns
end

# Fidelity warnings retained on a handle (`pio_warnings` / `pio_dist_warnings`):
# the readers that return a handle and no per-call warnbuf (`pio_read_dir`, the
# dist parsers) park their warnings here. The v4 query returns the joined text's
# byte length, so size with a null buffer first, then fill exactly — no cap
# marker, the buffer fits by construction. `query(out, cap)` closes over the
# handle, so the caller's GC.@preserve covers both calls (the raw pointer never
# travels alone; see `_normalize_handle`).
function _warnings_from(query)
    n = Int(query(C_NULL, Csize_t(0)))
    n == 0 && return String[]
    buf = zeros(UInt8, n + 1)  # +1 for the NUL the library always writes
    query(buf, Csize_t(length(buf)))
    return _warn_lines(buf)
end

_handle_warnings(h::BalancedNetworkHandle) =
    GC.@preserve h _warnings_from((out, cap) -> ccall((:pio_warnings, _lib()), Csize_t,
                                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, out, cap))

# The canonical `powerio-json` snapshot, the JSON transport `BalancedNetwork` is built
# from and `from_json` reads back. It is `pio_to_format` under the `powerio-json`
# name (v4 folded the old `pio_to_json` into the string-keyed writer). A lossy
# write (non-finite f64 → null) warns; this internal transport discards the
# warnbuf since the accessors read straight off the JSON.
function _to_json(h::BalancedNetworkHandle)
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_to_format, _lib()), Cstring,
                             (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                             h.ptr, "powerio-json", warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO: to_json failed: " * _cstr(err))
    json = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return json
end
