# --- library resolution -------------------------------------------------
#
# Resolution order: an in-session dev override (`set_library!`) first, then the
# `POWERIO_CAPI` environment variable, then a Preferences.jl library setting,
# then a sibling `../powerio` checkout's `target/{release,debug}` build, then the
# bundled `powerio_capi` artifact (the registered release path), then a plain
# `libpowerio_capi` on the loader path. The artifact lookup is lazy and guarded,
# so a not-yet-populated `Artifacts.toml` degrades to the loader path fallback
# instead of breaking module load.
#
# Once a `PowerIO_jll` is registered (issue #1, non-blocking) this whole block
# becomes `using PowerIO_jll` and `_lib() = PowerIO_jll.libpowerio_capi`.

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
    # The tracked preference above is already part of that image; traversing
    # Preferences' open Dict schema here also prevents trim verification. Leave
    # the session and environment refs untouched while generating it. The
    # load-time call below captures the process environment normally.
    ccall(:jl_generating_output, Cint, ()) != 0 && return
    # Overrides are read at init; the artifact/loader path fallback is resolved
    # and memoized lazily in `_lib()`.
    _SESSION_LIBRARY[] = ""
    _ENV_LIBRARY[] = get(ENV, "POWERIO_CAPI", "")
end

"""
    set_library!(path; persist=false)

Point PowerIO at a locally built `libpowerio_capi` (`cargo build -p powerio-capi
--release` in the PowerIO Rust tree → `target/release/libpowerio_capi.{dylib,so}`).
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
# `powerio_capi` entry for this platform (filled by `gen/update_artifacts.jl` from
# a tagged powerio release; see docs/src/binary.md), fall back to a plain
# `libpowerio_capi` on the loader path.
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
        @debug "PowerIO: powerio_capi artifact did not resolve; trying loader-path libpowerio_capi" exception = (e, catch_backtrace())
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

const PIO_ABI_VERSION = UInt32(5)
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

The `powerio-capi` crate version string the resolved library reports (e.g.
`"0.3.1"`). Informational; [`abi_version`](@ref) is the compatibility check.
"""
function library_version()
    s = ccall((:pio_version, _lib()), Cstring, ())
    return s == C_NULL ? "" : unsafe_string(s)  # 'static in the library; do not free
end

# Verify the resolved library is ABI-compatible, once (memoized). Throws a directed
# error otherwise; every entry point that calls into the library runs this first.
function _ensure_compatible(lib::AbstractString=_lib())
    lib = String(lib)
    _ABI_OK[] && _ABI_OK_LIB[] == lib && return
    got = try
        abi_version(lib)
    catch
        error("PowerIO: the C ABI at \"$lib\" has no pio_abi_version: it predates " *
              "the versioned ABI. Rebuild powerio-capi (`cargo build -p powerio-capi --release` " *
              "in a sibling powerio checkout), or check that the library path can be loaded.")
    end
    got == PIO_ABI_VERSION || error(
        "PowerIO: C ABI version mismatch: the library at \"$lib\" reports ABI $got, this PowerIO.jl " *
        "targets ABI $(PIO_ABI_VERSION). Rebuild powerio-capi from a matching commit, or " *
        "update PowerIO.jl.")
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
        # Probe: false means "not usable here". The logged message distinguishes
        # "library absent", "predates the versioned ABI", and "ABI mismatch".
        @debug "PowerIO: library unavailable or incompatible" exception = (e, catch_backtrace())
        return false
    end
end

# Shared probe behind `arrow_available`/`gridfm_available`: true if the resolved
# library exports `sym` (the feature-gated entry points come and go with cargo
# features, not the ABI version).
function _exports_symbol(sym::Symbol, lib::AbstractString=_lib())
    try
        return Libdl.dlsym(_library_handle(lib), sym; throw_error=false) !== nothing
    catch e
        @debug "PowerIO: $sym probe failed" exception = (e, catch_backtrace())
        return false
    end
end

# The classification families the core answers with, in its own spelling
# (`pio_classify_str`, and `json_classes` in `pio_build_info`). The set is
# closed and additive: a spelling is permanent and a new family appends.
const MODEL_JSON_FAMILY = Symbol("model-json")
const JSON_FAMILIES = (:transmission, :distribution, :package, MODEL_JSON_FAMILY,
                       :ambiguous, :unknown)

# Classify in-memory JSON by the core's cross-domain markers
# (`pio_classify_str`): one of `JSON_FAMILIES`. Older libraries lack the
# symbol; :unavailable keeps the caller on its pre-classify behavior (balanced
# inference and its errors).
function _classify_family(text::AbstractString)
    lib = _lib()
    _exports_symbol(:pio_classify_str, lib) || return :unavailable
    _ensure_compatible(lib)
    fn = _library_symbol(lib, :pio_classify_str)
    json = String(text)
    # `pio_classify_str` returns the full length and truncates into the buffer,
    # so size it first: nothing bounds a future format token.
    label = _string_from((out, cap) -> ccall(fn, Csize_t,
                                             (Cstring, Ptr{UInt8}, Csize_t), json, out, cap))
    isempty(label) && return :unknown
    return Symbol(first(split(label, ':')))
end

const _ERRLEN = 512

# ABI 5 hands the conversion's findings back through an out pointer as one
# owned JSON array of diagnostic records, so there is nothing to size and
# nothing to truncate. Before that this binding guessed 64 KiB and appended a
# "may be truncated" marker when the fill came near the cap, which is the wrong
# shape for an unbounded list: findings come one per lossy element, so a large
# case always beat the guess.
_diagref() = Ref{Ptr{UInt8}}(C_NULL)

"""
    Diagnostic <: AbstractString

One finding from a conversion. `code`, `severity`, and `message` are always
present; `stage`, `element_path`, `details`, `suggested_action`, and
`safe_to_ignore` appear when the finding carries them, and `record` is the whole
parsed record.

A `Diagnostic` renders, compares, and hashes as the `CODE: message` line the
conversion verbs return, so `occursin`, `split`, `join`, and `==` against a
`String` all read it as that line. Branch on `d.code` rather than splitting it.
Read them off [`to_format`](@ref), [`convert_file`](@ref), [`convert_str`](@ref),
and [`write_pypsa_csv_folder`](@ref); [`warnings`](@ref) reports a handle's
retained findings, which the C ABI carries as lines alone.
"""
struct Diagnostic <: AbstractString
    line::String
    record::JSON3.Object
end

Base.ncodeunits(d::Diagnostic) = ncodeunits(getfield(d, :line))
Base.codeunit(::Diagnostic) = UInt8
Base.codeunit(d::Diagnostic, i::Integer) = codeunit(getfield(d, :line), i)
Base.isvalid(d::Diagnostic, i::Integer) = isvalid(getfield(d, :line), i)
Base.iterate(d::Diagnostic) = iterate(getfield(d, :line))
Base.iterate(d::Diagnostic, i::Integer) = iterate(getfield(d, :line), i)
Base.String(d::Diagnostic) = getfield(d, :line)

function Base.getproperty(d::Diagnostic, name::Symbol)
    name === :line && return getfield(d, :line)
    name === :record && return getfield(d, :record)
    return getproperty(getfield(d, :record), name)
end

Base.propertynames(d::Diagnostic) = (:line, :record, propertynames(getfield(d, :record))...)

# Take ownership of the out-param diagnostics document and keep each record
# behind the `CODE: message` line the handle accessors return, so a conversion
# and a read report the same way and a caller can still reach the fields. A NULL
# out pointer means the conversion lost nothing.
function _take_warnings(lib::AbstractString, ref::Ref{Ptr{UInt8}})
    p = ref[]
    p == C_NULL && return Diagnostic[]
    document = _take_string(lib, Cstring(p))
    isempty(document) && return Diagnostic[]
    return [Diagnostic(string(r.code, ": ", r.message), r) for r in JSON3.read(document)]
end

# --- handle layer -------------------------------------------------------

# The allocating library's `pio_network_free`, memoized per resolved path:
# resolving `_lib()` at finalization time would cross allocators after a
# `set_library!` swap. The un-dlclosed handle deliberately keeps the library loaded so
# the pointer stays valid for every outstanding finalizer.
const _FREE_FN = Ref{Ptr{Cvoid}}(C_NULL)
const _FREE_FN_LIB = Ref{String}("")
function _network_free_fn(lib::AbstractString=_lib())
    lib = String(lib)
    if _FREE_FN[] == C_NULL || _FREE_FN_LIB[] != lib
        _FREE_FN[] = _library_symbol(lib, :pio_network_free)
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
    lib::String
    function BalancedNetworkHandle(ptr::Ptr{Cvoid}, lib::AbstractString=_lib())
        ptr == C_NULL && error("PowerIO: null network handle")
        # Resolve before `new`: a failed lookup must not strand a handle with
        # no finalizer attached.
        lib = String(lib)
        free = _network_free_fn(lib)
        h = new(ptr, lib)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(free, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end


# Directed error for when the ccall itself fails to dispatch — a missing library or
# undefined symbol — instead of a raw ccall fault far from the resolution site.
_lib_call_error(e) = error(
    "PowerIO: could not call the C ABI at \"$(_lib())\": build it " *
    "(`cargo build -p powerio-capi --release` in a sibling powerio checkout) " *
    "or call `set_library!` / set POWERIO_CAPI. Underlying: $e")
_lib_call_error() = error(
    "PowerIO: could not call the C ABI at \"$(_lib())\": build it " *
    "(`cargo build -p powerio-capi --release` in a sibling powerio checkout) " *
    "or call `set_library!` / set POWERIO_CAPI, and check that the path can be loaded.")

# Directed error for an entry point the resolved library predates: `sym` is
# absent even though the ABI handshake passes (additive symbols do not bump the
# ABI version). `hint` names the powerio release and cargo feature that ship it.
function _require_export(fname::AbstractString, sym::Symbol, hint::AbstractString,
                         lib::AbstractString=_lib())
    _exports_symbol(sym, lib) && return
    error("PowerIO.$fname: the C ABI at \"$lib\" does not export $sym ($hint). " *
          "Update the powerio_capi artifact or rebuild the local library.")
end

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
    lib = _lib()
    _ensure_compatible(lib)
    _network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    fromc = from === nothing ? C_NULL : String(from)
    ptr = try
        ccall(_library_symbol(lib, :pio_parse_file), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              path, fromc, err, length(err))
    catch
        _lib_call_error()
    end
    ptr == C_NULL && error("PowerIO.parse_file: " * _cstr(err))
    return BalancedNetworkHandle(ptr, lib)
end

# In-memory sibling of `_parse_handle`: parse `text` under an explicit `format`
# (no path, so no extension to infer from) via `pio_parse_str`.
function _parse_handle_str(text::AbstractString, format::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall(_library_symbol(lib, :pio_parse_str), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), String(format), err, length(err))
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.parse_str: " * _cstr(err))
    return BalancedNetworkHandle(ptr, lib)
end

# The byte sibling: `pio_parse_bytes` takes an explicit length, so the buffer
# needs no NUL and may hold binary. It is the only in-memory route to the
# PowerWorld `.pwb` reader. `GC.@preserve` roots the array for the call; the C
# side copies whatever it retains before returning.
function _parse_handle_bytes(bytes::AbstractVector{UInt8}, format::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    buf = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    ptr = try
        GC.@preserve buf begin
            ccall(_library_symbol(lib, :pio_parse_bytes), Ptr{Cvoid},
                  (Ptr{UInt8}, Csize_t, Cstring, Ptr{UInt8}, Csize_t),
                  pointer(buf), length(buf), String(format), err, length(err))
        end
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.parse_bytes: " * _cstr(err))
    return BalancedNetworkHandle(ptr, lib)
end

# `from_json` rebuilds from the canonical JSON snapshot `_to_json` writes.
# The distinct label keeps the error pointed at `from_json`.
function _from_json_handle(text::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _network_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall(_library_symbol(lib, :pio_from_json), Ptr{Cvoid},
              (Cstring, Ptr{UInt8}, Csize_t), String(text), err, length(err))
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.from_json: " * _cstr(err))
    return BalancedNetworkHandle(ptr, lib)
end

# `buf` must stay rooted across the unsafe_string read; without the preserve the
# compiler may drop the buffer after `pointer(buf)` and a GC mid-copy dangles.
_cstr(buf::Vector{UInt8}) = GC.@preserve buf unsafe_string(pointer(buf))

# The lookup key for a name the Rust core owns — a format name, a DC
# convention. Both separators are deleted rather than one folded into the
# other, because that is what the core's own `from_token` readers do: rewriting
# `-` to `_` instead refuses spellings the library accepts. The tables keyed by
# this live beside the routing they serve; the normalization is one rule and is
# shared so the two cannot drift apart from each other while both still claim
# to mirror the core.
_canonical_token_key(s) = replace(lowercase(String(s)), "-" => "", "_" => "")

# Owned Strings, one per non-empty line (a SubString would retain the whole
# buffer-sized parent).
_nonempty_lines(s::AbstractString) = String.(filter(!isempty, split(s, '\n')))

# One string over the cap/count convention (`pio_network_name`,
# `pio_source_format`, and the joined text behind `_warnings_from`): the query
# returns the byte length excluding the NUL, so size with a null buffer,
# allocate, fill exactly. `query(out, cap)` closes over the handle; the
# caller's GC.@preserve covers both calls (the raw pointer never travels
# alone; see `_normalize_handle`).
function _string_from(query)
    n = Int(query(C_NULL, Csize_t(0)))
    n == 0 && return ""
    buf = zeros(UInt8, n + 1)  # +1 for the NUL the library always writes
    query(buf, Csize_t(length(buf)))
    return _cstr(buf)
end

# JSON has no `Inf`/`NaN` literal, so a nonfinite float in the model document is
# spelled `"Infinity"`, `"-Infinity"`, or `"NaN"`. Every float read off a parsed
# payload goes through this, so an absent reactive limit arrives as `Inf`.
_json_float(::Type{T}, x) where {T<:Real} = T(x)
function _json_float(::Type{T}, x::AbstractString) where {T<:Real}
    x == "Infinity" && return T(Inf)
    x == "-Infinity" && return T(-Inf)
    x == "NaN" && return T(NaN)
    throw(ArgumentError(
        "PowerIO: $(repr(x)) is neither a number nor a nonfinite spelling " *
        "(\"Infinity\", \"-Infinity\", \"NaN\")"))
end
_json_float(x) = _json_float(Float64, x)

# Take ownership of a Rust-allocated C string: copy it to a Julia String and
# free the original with `pio_string_free`. The caller has already checked the
# pointer for NULL (each call site owns its own directed error).
function _take_string(lib::AbstractString, s::Cstring)
    text = unsafe_string(s)
    ccall(_library_symbol(lib, :pio_string_free), Cvoid, (Cstring,), s)
    return text
end

# Fidelity warnings retained on a handle (`pio_warnings` / `pio_dist_warnings`):
# the readers that return a handle and no per-call diagnostics channel
# (`pio_read_dir`, the dist parsers) park their findings here, already rendered
# as `CODE: message` lines. `_string_from` owns the size then fill
# protocol, so the joined text always fits by construction — no cap marker.
_warnings_from(query) = _nonempty_lines(_string_from(query))

_handle_warnings(h::BalancedNetworkHandle) =
    GC.@preserve h _warnings_from((out, cap) -> ccall(_library_symbol(getfield(h, :lib), :pio_warnings), Csize_t,
                                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, out, cap))

# The canonical JSON snapshot `BalancedNetwork` is built from and `from_json`
# reads back.
function _to_json(h::BalancedNetworkHandle)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_to_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    s == C_NULL && error("PowerIO: to_json failed: " * _cstr(err))
    return _take_string(lib, s)
end
