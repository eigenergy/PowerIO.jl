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
    lock(_LIB_HANDLES_LOCK) do
        _SESSION_LIBRARY[] = String(path)
        if persist
            set_preferences!(@__MODULE__, _LIBRARY_PREFERENCE => String(path); force=true)
            _PREFERRED_LIBRARY[] = String(path)
        end
        _ABI_OK[] = false  # the new library must pass its own handshake
        _ABI_OK_LIB[] = ""
        return
    end
end

"""
    clear_library!(; persist=false)

Clear the in-session library override. Pass `persist=true` to also clear the
saved Preferences.jl `library` override. `POWERIO_CAPI`, when set, still wins on
this session's next call.
"""
function clear_library!(; persist::Bool=false)
    lock(_LIB_HANDLES_LOCK) do
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
end

function _lib()
    lock(_LIB_HANDLES_LOCK) do
        isempty(_SESSION_LIBRARY[]) || return _SESSION_LIBRARY[]
        isempty(_ENV_LIBRARY[]) || return _ENV_LIBRARY[]
        isempty(_PREFERRED_LIBRARY[]) || return _PREFERRED_LIBRARY[]
        sib = _sibling_lib()
        isempty(sib) || return sib
        isempty(_RESOLVED[]) || return _RESOLVED[]
        return _RESOLVED[] = _artifact_lib()  # resolve once; bounds a failed lazy fetch to one attempt
    end
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

# --- entry point calls ---------------------------------------------------
#
# Every call into the C library goes through `LibPowerIO`, whose argument and
# return types come from `powerio.h` by way of gen/generate.jl. The symbol is
# resolved against the library chosen for this call, so a `set_library!` swap
# takes effect immediately and no call is bound to a library at load time.

"""
    @capi lib :pio_abi_version()

Call the named C entry point in the library at `lib`, as in
`@capi lib :pio_balanced_network_bus_count(network)`. Expands to the
`LibPowerIO` method that takes a resolved function pointer as its last
argument, so the argument and return types are the header's.

The name is normally quoted. A plain variable holding a `Symbol` also works;
the method is then looked up by name at the call.
"""
macro capi(lib, call)
    Meta.isexpr(call, :call) ||
        throw(ArgumentError("@capi expects a call, as in `@capi lib :pio_abi_version()`"))
    callee = call.args[1]
    args = map(esc, call.args[2:end])
    callee isa QuoteNode &&
        return :(@inline LibPowerIO.$(callee.value)($(args...),
                                                    _library_symbol($(esc(lib)), $callee)))
    return :(_capi($(esc(lib)), $(esc(callee)), $(args...)))
end

# `@capi` where a helper takes the entry point as a parameter. A `Val` holding
# the name carries it in the type, so the helper compiles one specialization
# per entry point and the call into `LibPowerIO` resolves at compile time. The
# element tables read every row through this path, and a name passed as a plain
# `Symbol` there costs a dynamic lookup and a boxed return on every field.
#
# The generated `LibPowerIO` method is one `@ccall`, but its inlining cost sits
# above the default threshold, so the call-site `@inline` is what keeps it from
# compiling to an `invoke`. Out-parameter cells reach a `ccall` that is inlined
# into the caller as stack slots; reaching an `invoke` instead makes them
# escape, and the element tables would heap-allocate an output cell and an
# error cell on every row.
@inline _capi(lib::AbstractString, ::Val{S}, args...) where {S} =
    @inline getfield(LibPowerIO, S)(args..., _library_symbol(lib, S))

# The same for a name that is genuinely only known at run time, such as one
# looked up in a table keyed by a structural type name.
_capi(lib::AbstractString, sym::Symbol, args...) =
    getfield(LibPowerIO, sym)(args..., _library_symbol(lib, sym))

# --- borrowed spans ------------------------------------------------------
#
# Every span the C ABI hands back is a (pointer, length) pair valid only while
# the handle that owns it lives. These helpers copy into owned Julia values
# before the caller can release that handle.

# Copy a borrowed string span into an owned `String`. An empty span is "".
function _str(v::PioStringView)
    (v.data == C_NULL || v.len == 0) && return ""
    return unsafe_string(Ptr{UInt8}(v.data), Int(v.len))
end

# `nothing` when the presence flag is false, the copied string otherwise.
_optional_str(v::PioStringView, present::Bool) = present ? _str(v) : nothing

_optional(value, present::Bool) = present ? value : nothing

# Copy a borrowed double span into an owned vector.
function _f64s(v::PioF64View)
    (v.data == C_NULL || v.len == 0) && return Float64[]
    return copy(unsafe_wrap(Vector{Float64}, v.data, Int(v.len)))
end

_optional_f64s(v::PioF64View, present::Bool) = present ? _f64s(v) : nothing

# Copy a borrowed size span into an owned `Vector{Int}`.
function _sizes(v::PioSizeView)
    (v.data == C_NULL || v.len == 0) && return Int[]
    return Int.(unsafe_wrap(Vector{Csize_t}, v.data, Int(v.len)))
end

# Copy a borrowed byte span into an owned vector.
function _bytes(v::PioByteView)
    (v.data == C_NULL || v.len == 0) && return UInt8[]
    return copy(unsafe_wrap(Vector{UInt8}, v.data, Int(v.len)))
end

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

# When a development checkout of this package sits beside a `powerio`
# checkout, resolve the locally built cdylib from
# `../powerio/target/{release,debug}`. Release wins over debug; returns ""
# when no sibling build is present. A registry install has no `.git` and
# never loads a library from this unpinned path.
function _sibling_lib()
    isdir(joinpath(dirname(@__DIR__), ".git")) || return ""
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

# The header states the ABI version this binding was generated against.
const PIO_ABI_VERSION = UInt32(LibPowerIO.PIO_ABI_VERSION)
const _ABI_OK = Ref{Bool}(false)
const _ABI_OK_LIB = Ref{String}("")

"""
    abi_version() -> UInt32

The ABI version the resolved C library was built with (see `pio_abi_version`).
Compared against `PIO_ABI_VERSION`, the version this binding targets.
"""
abi_version() = abi_version(_lib())
abi_version(lib::AbstractString) =
    @capi lib :pio_abi_version()

"""
    library_version() -> String

The powerio crate version string the resolved library reports, such as
`"0.11.0"`. Informational; [`abi_version`](@ref) is the compatibility check.
"""
function library_version(lib::AbstractString=_lib())
    _ensure_compatible(lib)
    return _str(@capi lib :pio_version())
end

# Verify the resolved library is ABI compatible, once per library path. Throws
# a directed error otherwise; every entry point that calls into the library
# runs this first.
function _ensure_compatible(lib::AbstractString=_lib())
    lib = String(lib)
    lock(_LIB_HANDLES_LOCK) do
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
        for sym in _HANDLE_RELEASE_SYMBOLS
            _library_symbol(lib, sym)
        end
        _ABI_OK[] = true
        _ABI_OK_LIB[] = lib
        return
    end
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
function _take_string(lib::AbstractString, ptr::Ptr)
    ptr == C_NULL && return ""
    h = StringHandle(ptr, lib)
    text = _with_handles(h) do
        _str(@capi lib :pio_string_view(_ptr(h)))
    end
    release!(h)
    return text
end
