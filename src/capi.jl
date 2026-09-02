# --- library resolution -------------------------------------------------
#
# Resolution order: an in-session override (`set_library!`), then the
# `POWERIO_CAPI` environment variable, then a Preferences.jl library setting,
# then a sibling `../powerio` checkout's `target/{release,debug}` build, then
# the bundled `powerio_capi` artifact, then a plain `libpowerio_capi` on the
# loader path. The artifact lookup is lazy, so an unpopulated `Artifacts.toml`
# degrades to the loader path fallback instead of breaking module load.

const _SESSION_LIBRARY = Ref{String}("")    # set_library! override; "" means unset
const _ENV_LIBRARY = Ref{String}("")        # POWERIO_CAPI captured at module init
const _LIBRARY_PREFERENCE = "library"
const _PREFERRED_LIBRARY = Ref{String}(let value = @load_preference(_LIBRARY_PREFERENCE, "")
    value isa AbstractString ? String(value) : ""
end)                                        # Preferences.jl override
const _RESOLVED = Ref{String}("")           # memoized artifact / loader path resolution
const _LIB_HANDLES = Dict{String,Ptr{Nothing}}()
const _LIB_HANDLES_LOCK = ReentrantLock()

function __init__()
    # Julia calls package initializers again when it loads a generated image.
    # The tracked preference above is already part of that image, and reading
    # Preferences' open Dict schema here prevents trim verification, so the
    # session and environment refs stay untouched while generating one.
    ccall(:jl_generating_output, Cint, ()) != 0 && return
    _SESSION_LIBRARY[] = ""
    _ENV_LIBRARY[] = get(ENV, "POWERIO_CAPI", "")
end

"""
    set_library!(path; persist=false)

Point PowerIO at a locally built `libpowerio_capi` (`cargo build -p powerio-capi
--release` in the powerio Rust tree writes `target/release/libpowerio_capi.{dylib,so}`).
An in-session override wins over `POWERIO_CAPI`, the saved Preferences.jl
override, and the bundled artifact. Pass `persist=true` to save the path in the
active environment's `LocalPreferences.toml`.
"""
function set_library!(path::AbstractString; persist::Bool=false)
    _SESSION_LIBRARY[] = String(path)
    if persist
        set_preferences!(@__MODULE__, _LIBRARY_PREFERENCE => String(path); force=true)
        _PREFERRED_LIBRARY[] = String(path)
    end
    _ABI_OK[] = false  # the new library must pass its own handshake
    _ABI_OK_LIB[] = ""
    return
end

"""
    clear_library!(; persist=false)

Clear the in-session library override. Pass `persist=true` to also clear the
saved Preferences.jl `library` override. `POWERIO_CAPI`, when set, still wins on
this session's next call.
"""
function clear_library!(; persist::Bool=false)
    _SESSION_LIBRARY[] = ""
    if persist
        set_preferences!(@__MODULE__, _LIBRARY_PREFERENCE => missing; force=true)
        value = load_preference(@__MODULE__, _LIBRARY_PREFERENCE, "";
                                disable_invalidation=true)
        _PREFERRED_LIBRARY[] = value isa AbstractString ? String(value) : ""
    end
    _ABI_OK[] = false
    _ABI_OK_LIB[] = ""
    return
end

function _lib()
    isempty(_SESSION_LIBRARY[]) || return _SESSION_LIBRARY[]
    isempty(_ENV_LIBRARY[]) || return _ENV_LIBRARY[]
    isempty(_PREFERRED_LIBRARY[]) || return _PREFERRED_LIBRARY[]
    sib = _sibling_lib()
    isempty(sib) || return sib
    isempty(_RESOLVED[]) || return _RESOLVED[]
    return _RESOLVED[] = _artifact_lib()  # resolve once; bounds a failed lazy fetch to one attempt
end

function _library_handle(lib::AbstractString)
    lib = String(lib)
    lock(_LIB_HANDLES_LOCK)
    try
        return get!(_LIB_HANDLES, lib) do
            Libdl.dlopen(lib)
        end
    finally
        unlock(_LIB_HANDLES_LOCK)
    end
end

_library_symbol(lib::AbstractString, sym::Symbol) =
    Libdl.dlsym(_library_handle(lib), sym)

# Resolve the bundled `powerio_capi` artifact. Until `Artifacts.toml` carries a
# `powerio_capi` entry for this platform (filled by `gen/update_artifacts.jl`
# from a tagged powerio release; see docs/src/binary.md), fall back to a plain
# `libpowerio_capi` on the loader path. The subdir mirrors what
# `gen/build_tarballs.jl` installs: the Windows dll under `bin/`, the shared
# object under `lib/` everywhere else.
function _artifact_lib()
    libsubdir = Sys.iswindows() ? "bin" : "lib"
    try
        return joinpath(artifact"powerio_capi", libsubdir, "libpowerio_capi.$(Libdl.dlext)")
    catch e
        @debug "PowerIO: powerio_capi artifact did not resolve; trying loader-path libpowerio_capi" exception = (e, catch_backtrace())
        return "libpowerio_capi"
    end
end

# When this package sits beside a `powerio` checkout, resolve the locally built
# cdylib from `../powerio/target/{release,debug}`. Release wins over debug;
# returns "" when no sibling build is present.
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
# The C ABI carries an integer ABI version (`pio_abi_version`). This binding
# targets exactly `PIO_ABI_VERSION`. Checking it once at first use turns a
# stale or mismatched library into a clear error at the boundary instead of a
# ccall fault or silently wrong numbers.

const PIO_ABI_VERSION = UInt32(7)
const _ABI_OK = Ref{Bool}(false)
const _ABI_OK_LIB = Ref{String}("")

"""
    abi_version() -> UInt32

The ABI version the resolved C library was built with (see `pio_abi_version`).
Compared against `PIO_ABI_VERSION`, the version this binding targets.
"""
abi_version() = abi_version(_lib())
abi_version(lib::AbstractString) =
    ccall(_library_symbol(lib, :pio_abi_version), UInt32, ())

"""
    library_version() -> String

The powerio crate version string the resolved library reports, such as
`"1.0.0"`. Informational; [`abi_version`](@ref) is the compatibility check.
"""
function library_version(lib::AbstractString=_lib())
    _ensure_compatible(lib)
    return _str(ccall(_library_symbol(lib, :pio_version), PioStringView, ()))
end

# Verify the resolved library is ABI compatible, once per library path. Throws
# a directed error otherwise; every entry point that calls into the library
# runs this first.
function _ensure_compatible(lib::AbstractString=_lib())
    lib = String(lib)
    _ABI_OK[] && _ABI_OK_LIB[] == lib && return
    got = try
        abi_version(lib)
    catch
        error("PowerIO: the C ABI at \"$lib\" has no pio_abi_version. Build " *
              "powerio-capi (`cargo build -p powerio-capi --release` in a powerio " *
              "checkout), or check that the library path can be loaded.")
    end
    got == PIO_ABI_VERSION || error(
        "PowerIO: C ABI version mismatch: the library at \"$lib\" reports ABI $got, " *
        "this PowerIO.jl targets ABI $(Int(PIO_ABI_VERSION)). Rebuild powerio-capi " *
        "from a matching commit, or update PowerIO.jl.")
    _ABI_OK[] = true
    _ABI_OK_LIB[] = lib
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
        @debug "PowerIO: library unavailable or incompatible" exception = (e, catch_backtrace())
        return false
    end
end

# The library every operation binds against: resolved, handshake passed.
function _checked_lib()
    lib = _lib()
    _ensure_compatible(lib)
    return lib
end

# Copy an owned `PioString` into a Julia `String` and release it.
function _take_string(lib::AbstractString, ptr::Ptr{Cvoid})
    ptr == C_NULL && return ""
    h = StringHandle(ptr, lib)
    text = GC.@preserve h _str(ccall(_library_symbol(lib, :pio_string_view), PioStringView,
                                     (Ptr{Cvoid},), _ptr(h)))
    release!(h)
    return text
end
