"""
    PowerIO

Julia bindings for the PowerIO Rust core: parse MATPOWER / PSS/E / PowerWorld /
PowerModels JSON / egret JSON case files, convert between any pair (byte exact on a
same-format round trip, maximal fidelity otherwise), and materialize an immutable
`BalancedNetwork`, all through the `powerio-capi` C ABI.

Parse once with [`parse_file`](@ref) → [`BalancedNetwork`](@ref), then read or transform it,
all over the same C ABI:

- the rich, lossless element tables via the JSON transport (every field + extras,
  costs, storage, HVDC): the accessors and [`to_json`](@ref).
- [`to_dense`](@ref): the numeric tables as dense typed arrays for matrix assembly,
  straight from the C ABI extractors, no JSON.
- [`to_arrow`](@ref): one table over the Arrow C Data Interface (owned columns by
  default; zero copy with `copy=false`).

[`to_normalized`](@ref) derives a per unit / radian / filtered copy that preserves
source bus ids, and
[`to_matpower`](@ref) / [`convert_file`](@ref) serialize back out.

[`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) read a gridfm-datakit Parquet
dataset back into a `BalancedNetwork` (the ML→classical return leg; lossy but complete
enough for power flow, needs powerio-capi built `--features gridfm`).

Multiconductor distribution cases are a separate model on their own
[`MulticonductorNetwork`](@ref) handle, sharing the same verbs: `parse_file(MulticonductorNetwork, path)`,
`to_format(net, to)`, `convert_file(MulticonductorNetwork, path, to)` read and write OpenDSS,
PowerModelsDistribution JSON, and IEEE BMOPF JSON (experimental; needs powerio-capi
built `--features dist`).

At first use the binding checks the library's ABI version (`pio_abi_version`)
against the version it targets (`PIO_ABI_VERSION`) and refuses a stale or
mismatched library with an error stating both versions. Distribution calls also
check `pio_dist_abi_version` against `PIO_DIST_ABI_VERSION`.

The C library resolves automatically: the bundled lazy artifact, or a sibling
powerio build during development. Point at a custom build with
[`set_library!`](@ref) or the `POWERIO_CAPI` environment variable.
"""
module PowerIO

using JSON3
using LazyArtifacts
import Libdl

export BalancedNetwork, parse_file, parse_str, from_json, convert_file, convert_str,
       to_format, to_normalized, to_json, to_dense, to_matpower, to_arrow,
       ArrowTable, write_pypsa_csv_folder, to_powermodels, from_powermodels,
       to_powerdata, parse_ac_power_data, read_gridfm, read_gridfm_scenarios,
       CompilerPackage, to_package, from_package, read_package, write_package,
       package_model_kind, arrow_available, gridfm_available, MulticonductorNetwork,
       dist_available, dist_abi_version

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
# a tagged powerio release; see docs/binary.md), fall back to a plain
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
    NetworkHandle

Opaque handle to a parsed network inside the Rust core. Freed by its finalizer;
you normally go straight to [`parse_file`](@ref), which returns a [`BalancedNetwork`].
"""
mutable struct NetworkHandle
    ptr::Ptr{Cvoid}
    function NetworkHandle(ptr::Ptr{Cvoid})
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
    return NetworkHandle(ptr)
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
    return NetworkHandle(ptr)
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
    return NetworkHandle(ptr)
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

_handle_warnings(h::NetworkHandle) =
    GC.@preserve h _warnings_from((out, cap) -> ccall((:pio_warnings, _lib()), Csize_t,
                                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, out, cap))

# The canonical `powerio-json` snapshot, the JSON transport `BalancedNetwork` is built
# from and `from_json` reads back. It is `pio_to_format` under the `powerio-json`
# name (v4 folded the old `pio_to_json` into the string-keyed writer). A lossy
# write (non-finite f64 → null) warns; this internal transport discards the
# warnbuf since the accessors read straight off the JSON.
function _to_json(h::NetworkHandle)
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

# --- public surface -----------------------------------------------------

"""
    BalancedNetwork

An immutable view of a parsed case, materialized from the C ABI's JSON transport.
Raw MATPOWER units and 1-based bus ids, mirroring `powerio`'s `BalancedNetwork`: buses,
loads, shunts, branches, generators, storage, and hvdc tables plus `base_mva`,
`name`, and `source_format` (the format it was read from). For now the tables are
the parsed JSON (`net.data`).

A `BalancedNetwork` from [`parse_file`](@ref) also keeps its live Rust [`NetworkHandle`](@ref)
(`net.handle`), so the `to_*` transforms ([`to_normalized`](@ref), [`to_dense`](@ref),
[`to_matpower`](@ref), [`to_arrow`](@ref)) work straight off it. The handle's
finalizer frees the Rust case once the `BalancedNetwork` is unreachable. A `BalancedNetwork` constructed
from a bare `JSON3.Object` has `handle === nothing`; the accessors and [`to_json`](@ref) work
on it, but the handle-only transforms error.
"""
struct BalancedNetwork
    data::JSON3.Object
    handle::Union{NetworkHandle,Nothing}
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
    parse_file(path; from=nothing) -> BalancedNetwork
    parse_file(io::IO, format::AbstractString) -> BalancedNetwork
    parse_file(MulticonductorNetwork, path; from=nothing) -> MulticonductorNetwork

Parse a case into a [`BalancedNetwork`].

From a file `path` the format is inferred from the extension unless `from` is given
(needed to tell egret and PowerModels `.json` apart). From an `io` stream the
`format` is required (there is no extension); parse in-memory text by wrapping it,
`parse_file(IOBuffer(text), "matpower")`.

Accepted format tokens (case-insensitive): `"matpower"`/`"m"`, `"powermodels-json"`/
`"powermodels"`/`"pm"`, `"egret-json"`/`"egret"`, `"psse"`/`"raw"`,
`"powerworld"`/`"aux"`.

Pass [`MulticonductorNetwork`](@ref) as the first argument to parse a multiconductor
distribution case instead (`parse_file(MulticonductorNetwork, path)`); `BalancedNetwork` is the
default, the `parse(T, x)` idiom. See the `src/dist.jl` surface.
"""
function parse_file(path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
end
function parse_file(io::IO, format::AbstractString)
    h = _parse_handle_str(read(io, String), format)
    return BalancedNetwork(JSON3.read(_to_json(h)), h)
end
# Explicit transmission marker, symmetric with `parse_file(MulticonductorNetwork, ...)`.
parse_file(::Type{BalancedNetwork}, path::AbstractString; from=nothing) = parse_file(path; from=from)

"""
    parse_str(text, format="matpower") -> BalancedNetwork
    parse_str(MulticonductorNetwork, text, format) -> MulticonductorNetwork

Parse in-memory case text into a [`BalancedNetwork`](@ref). This is the string sibling of
`parse_file(io, format)`, matching the Rust, Python, and C interfaces. Pass
[`MulticonductorNetwork`](@ref) first for a distribution case.
"""
parse_str(text::AbstractString, format::AbstractString="matpower") =
    parse_file(IOBuffer(String(text)), format)
parse_str(::Type{BalancedNetwork}, text::AbstractString, format::AbstractString="matpower") =
    parse_str(text, format)

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
function _normalize_handle(h::NetworkHandle)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall((:pio_normalize, _lib()), Ptr{Cvoid},
                               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    ptr == C_NULL && error("PowerIO.to_normalized: " * _cstr(err))
    return NetworkHandle(ptr)
end

"""
    to_normalized(net::BalancedNetwork) -> BalancedNetwork

A computation-ready copy of `net`: per unit (powers ÷ `base_mva`), angles in
radians, transformer tap `0 → 1`, out-of-service and isolated elements dropped,
source bus ids preserved, and bus types inferred (a bus with a surviving generator
keeps `REF` if the source marked it so, else becomes `PV`; a generator-less bus
becomes `PQ`). `source_format` of the result is `"Normalized"`.

Needs `net`'s live Rust handle (from [`parse_file`](@ref)). Errors if `base_mva` is
not positive or no reference bus can be established.
"""
function to_normalized(net::BalancedNetwork)
    hn = _normalize_handle(_live_handle(net, "to_normalized"))
    return BalancedNetwork(JSON3.read(_to_json(hn)), hn)
end

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

function _format_from_handle(h::NetworkHandle, to::AbstractString, what::AbstractString)
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_to_format, _lib()), Cstring,
                             (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                             h.ptr, String(to), warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.to_format: " * _cstr(err) * " ($what)")
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
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

Convert `path` to format `to`. All five formats read and write, so any pair
converts. A same-format conversion is byte exact; a cross-format one is
maximal fidelity and reports whatever the target can't carry in `warnings`. Tokens
(case-insensitive): `"matpower"`/`"m"`, `"powermodels-json"`/`"powermodels"`/`"pm"`,
`"egret-json"`/`"egret"`, `"psse"`/`"raw"`, `"powerworld"`/`"aux"`. `from` overrides
extension inference (needed to tell egret and PowerModels `.json` apart). Pass
[`MulticonductorNetwork`](@ref) first to convert a distribution case.
"""
function convert_file(path::AbstractString, to::AbstractString; from=nothing)
    _ensure_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    # v4 argument order is (path, from, to), matching pio_to_format / pio_parse_str.
    fromc = from === nothing ? C_NULL : String(from)
    s = ccall((:pio_convert_file, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              path, fromc, to, warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.convert_file: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
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
    _ensure_compatible()
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    # v4 argument order is (text, from, to), matching pio_convert_file.
    s = ccall((:pio_convert_str, _lib()), Cstring,
              (Cstring, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              String(text), String(from), to, warnbuf, length(warnbuf), err, length(err))
    s == C_NULL && error("PowerIO.convert_str: " * _cstr(err))
    out = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
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
    warnbuf = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    # `pio_write_dir` is the generic directory writer; `pypsa-csv` is the one such
    # format today. Fallible `int` return (0 = success), the warnbuf/errbuf
    # convention of `pio_to_format`; the handle is preserved across the ccall.
    rc = GC.@preserve h ccall((:pio_write_dir, _lib()), Int32,
                              (Ptr{Cvoid}, Cstring, Cstring, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                              h.ptr, "pypsa-csv", String(out_dir), warnbuf, length(warnbuf), err, length(err))
    rc == 0 || error("PowerIO.write_pypsa_csv_folder: " * _cstr(err))
    return (String(out_dir), _warn_lines(warnbuf; capped=true))
end

# --- accessor surface ---------------------------------------------------
#
# The v0.0.1 surface bridges read: the parsed element tables plus a few scalars.
# Element field names mirror the Rust `BalancedNetwork` (powerio/src/network.rs) and are
# the stable contract — raw MATPOWER units (MW/MVAr, degrees), 1-based bus ids,
# out-of-service elements retained, so a consumer normalizes as it sees fit:
#
#   bus:     id, kind ∈ {"PQ","PV","REF","ISOLATED"}, vm, va (deg), base_kv,
#            vmax, vmin, area, zone, name, extras
#   gen:     bus, pg, qg, pmax, pmin, qmax, qmin, vg, mbase, in_service,
#            cost (`nothing`, or {model, startup, shutdown, ncost, coeffs}),
#            caps (ordered 11-element nullable array
#            [pc1, pc2, qc1min, qc1max, qc2min, qc2max, ramp_agc, ramp_10,
#            ramp_30, ramp_q, apf])
#   branch:  from, to, r, x, b, rate_a, rate_b, rate_c, tap, shift (deg),
#            in_service, angmin (deg), angmax (deg), extras
#   load:    bus, p (MW), q (MVAr), in_service, extras
#   shunt:   bus, g, b, in_service, extras
#   storage: bus, ps, qs, energy, energy_rating, charge_rating, discharge_rating,
#            charge_efficiency, discharge_efficiency, thermal_rating, qmin, qmax,
#            r, x, p_loss, q_loss, in_service, extras
#   hvdc:    from, to, in_service, pf, pt, qf, qt, vf, vt, pmin, pmax, qminf,
#            qmaxf, qmint, qmaxt, loss0, loss1, extras
#
# Plus scalars: `base_mva`, `network_name`, `source_format`, `reference_bus_id`.
# The fully typed struct mirroring `network.rs` and the dense-extraction fast path
# are v0.1.0 (issue #2); these views are enough for the ecosystem bridges.

n_buses(net::BalancedNetwork) = length(net.data.buses)
n_branches(net::BalancedNetwork) = length(net.data.branches)
base_mva(net::BalancedNetwork) = Float64(net.data.base_mva)

"""
    network_name(net) -> String

The case name carried through from the source file.
"""
network_name(net::BalancedNetwork) = String(net.data.name)

"Buses, in source order (1-based ids preserved). See the accessor-surface note."
buses(net::BalancedNetwork) = net.data.buses
"Generators, one per machine (`bus` repeats when a bus has several)."
generators(net::BalancedNetwork) = net.data.generators
"Branches (lines and transformers), in source order."
branches(net::BalancedNetwork) = net.data.branches
"First-class loads (PSS/E and PowerModels keep several per bus; MATPOWER splits its bus row)."
loads(net::BalancedNetwork) = net.data.loads
"First-class bus shunts."
shunts(net::BalancedNetwork) = net.data.shunts
"First-class storage units; empty unless the source carries them (PowerModels, egret)."
storage(net::BalancedNetwork) = net.data.storage
"Two-terminal HVDC lines (MATPOWER `dcline`); empty unless the source carries them."
hvdc(net::BalancedNetwork) = net.data.hvdc

"""
    n_gens(net) -> Int

Number of generator rows (one per machine; `bus` repeats). Matches `pio_n_gens`:
every row, not in-service-filtered.
"""
n_gens(net::BalancedNetwork) = length(net.data.generators)

"""
    source_format(net) -> String

The format the case was read from, verbatim from the Rust `SourceFormat` enum:
one of `"Matpower"`, `"PowerModelsJson"`, `"EgretJson"`, `"Psse"`, `"PowerWorld"`,
`"InMemory"`, `"Normalized"` (the last is the output of [`to_normalized`](@ref)).
"""
source_format(net::BalancedNetwork) = String(net.data.source_format)

"""
    reference_bus_id(net) -> Union{Int,Nothing}

The 1-based id of the reference (slack) bus, or `nothing` unless exactly one bus
has `kind == "REF"`. This mirrors the "exactly one" rule of the C ABI's
`pio_ref_bus_index` (which returns a dense 0-based index, not an id), but returns
the 1-based id space the other accessors use.
"""
function reference_bus_id(net::BalancedNetwork)
    ref = nothing
    for b in net.data.buses
        if String(b.kind) == "REF"
            ref === nothing || return nothing  # more than one REF: no unique slack
            ref = Int(b.id)
        end
    end
    return ref
end

"""
    reference_bus_indices(net) -> Vector{Int}

The dense `[0, n)` indices of every reference (slack) bus, in dense bus order.
Unlike [`reference_bus_id`](@ref) — which returns a single 1-based id and only
when exactly one bus is `REF` — this returns all of them (zero, one, or many) as
dense indices. Map an index back to a 1-based id with `to_dense(net).bus_ids`.
Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function reference_bus_indices(net::BalancedNetwork)
    h = _live_handle(net, "reference_bus_indices")
    # v4 folds the count and fill into one `pio_ref_bus_indices(net, out, cap)`
    # (writes up to `cap`, returns the total): size with a null buffer, then fill.
    return GC.@preserve h begin
        n = Int(ccall((:pio_ref_bus_indices, _lib()), Csize_t,
                      (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, C_NULL, 0))
        out = Vector{Int64}(undef, n)
        _check_filled(ccall((:pio_ref_bus_indices, _lib()), Csize_t,
                            (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, out, n), n, "pio_ref_bus_indices")
        Vector{Int}(out)
    end
end

"""
    n_components(net) -> Int

Number of connected components of the in-service topology, as the C ABI computes it
(`pio_n_islands`). The same quantity as `to_dense(net).n_components`, without
building the dense view. Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function n_components(net::BalancedNetwork)
    h = _live_handle(net, "n_components")
    return Int(GC.@preserve h ccall((:pio_n_islands, _lib()), Csize_t, (Ptr{Cvoid},), h.ptr))
end

"""
    is_radial(net) -> Bool

Whether the in-service topology is radial (a forest), as the C ABI computes it
(`pio_is_radial`). The same quantity as `to_dense(net).is_radial`, without building
the dense view. Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function is_radial(net::BalancedNetwork)
    h = _live_handle(net, "is_radial")
    return (GC.@preserve h ccall((:pio_is_radial, _lib()), Cint, (Ptr{Cvoid},), h.ptr)) != 0
end

"""
    bus_type_code(kind) -> Int

Map the canonical bus-type string (`"PQ"`, `"PV"`, `"REF"`, `"ISOLATED"`) to the
MATPOWER code (1, 2, 3, 4). The strings are the Rust core's `BusType::as_str`
values.
"""
function bus_type_code(kind::AbstractString)
    kind == "PQ"       && return 1
    kind == "PV"       && return 2
    kind == "REF"      && return 3
    kind == "ISOLATED" && return 4
    throw(ArgumentError("PowerIO: unknown bus type $(repr(kind))"))
end

# --- dense numeric surface ----------------------------------------------
#
# The JSON transport above is the rich, lossless view (every field + extras). For
# the matrix-assembly path a consumer wants the numeric tables as dense typed
# arrays without parsing JSON: the C ABI fills caller-allocated buffers
# (`pio_bus_ids` / `pio_branches` / `pio_gens` / `pio_bus_demand` / `pio_bus_shunt`)
# straight from the IndexCore the handle built once at parse, and answers the
# topology scalars (`pio_n_islands` / `pio_is_radial` / `pio_ref_bus_index`) off the same core.
# Raw MATPOWER units throughout: 1-based bus ids in `bus_ids`, branch `from`/`to`,
# and gen `bus` (the same id space — invert `bus_ids` to map an endpoint to a dense
# row), degrees for `shift`, total line charging in `b`, raw `tap` (0 means 1).
#
# Every helper takes the NetworkHandle and preserves it across its ccalls (the
# raw pointer never travels alone); see `_normalize_handle` for why.

# The v4 extractors take a `cap` and return the total count (write up to `cap`,
# never overflow). The counts come from `pio_n_*` on the same immutable handle, so
# `cap == count`; verifying the return catches an ABI contract violation cheaply
# (the cap/count convention exists precisely so a short fill is detectable). Any
# output pointer may be NULL to skip.
function _check_filled(got, want::Int, what::AbstractString)
    Int(got) == want || error("PowerIO: $what returned $got of $want expected " *
                              "(a cap/count mismatch — incompatible C ABI?)")
    return
end

function _branch_tables(h::NetworkHandle, m::Int)
    from = Vector{Int64}(undef, m); to = Vector{Int64}(undef, m)
    r = Vector{Float64}(undef, m); x = Vector{Float64}(undef, m); b = Vector{Float64}(undef, m)
    tap = Vector{Float64}(undef, m); shift = Vector{Float64}(undef, m)
    insvc = Vector{UInt8}(undef, m)
    got = GC.@preserve h ccall((:pio_branches, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}, Csize_t),
          h.ptr, from, to, r, x, b, tap, shift, insvc, m)
    _check_filled(got, m, "pio_branches")
    return (; from, to, r, x, b, tap, shift, in_service = insvc)
end

function _gen_tables(h::NetworkHandle, ng::Int)
    bus = Vector{Int64}(undef, ng); pg = Vector{Float64}(undef, ng)
    pmax = Vector{Float64}(undef, ng); pmin = Vector{Float64}(undef, ng)
    insvc = Vector{UInt8}(undef, ng)
    got = GC.@preserve h ccall((:pio_gens, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}, Csize_t),
          h.ptr, bus, pg, pmax, pmin, insvc, ng)
    _check_filled(got, ng, "pio_gens")
    return (; bus, pg, pmax, pmin, in_service = insvc)
end

function _bus_demand(h::NetworkHandle, n::Int)
    pd = Vector{Float64}(undef, n); qd = Vector{Float64}(undef, n)
    got = GC.@preserve h ccall((:pio_bus_demand, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Csize_t), h.ptr, pd, qd, n)
    _check_filled(got, n, "pio_bus_demand")
    return (pd, qd)
end

function _bus_shunt(h::NetworkHandle, n::Int)
    gs = Vector{Float64}(undef, n); bs = Vector{Float64}(undef, n)
    got = GC.@preserve h ccall((:pio_bus_shunt, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Csize_t), h.ptr, gs, bs, n)
    _check_filled(got, n, "pio_bus_shunt")
    return (gs, bs)
end

# Dense numeric extraction off a live handle, shared by the BalancedNetwork and path
# methods. The whole body runs under GC.@preserve h: a dozen ccalls with Julia
# allocations between them, exactly the shape where a finalizer racing the raw
# pointer would be a use after free.
function _dense_from_handle(h::NetworkHandle)
    GC.@preserve h begin
        p = h.ptr
        n = Int(ccall((:pio_n_buses, _lib()), Csize_t, (Ptr{Cvoid},), p))
        m = Int(ccall((:pio_n_branches, _lib()), Csize_t, (Ptr{Cvoid},), p))
        ng = Int(ccall((:pio_n_gens, _lib()), Csize_t, (Ptr{Cvoid},), p))
        bus_ids = Vector{Int64}(undef, n)
        _check_filled(ccall((:pio_bus_ids, _lib()), Csize_t,
                            (Ptr{Cvoid}, Ptr{Int64}, Csize_t), p, bus_ids, n), n, "pio_bus_ids")
        pd, qd = _bus_demand(h, n)
        gs, bs = _bus_shunt(h, n)
        return (;
            n, m, ng,
            base_mva = ccall((:pio_base_mva, _lib()), Cdouble, (Ptr{Cvoid},), p),
            bus_ids,
            branch = _branch_tables(h, m),
            gen = _gen_tables(h, ng),
            demand = (; pd, qd),
            shunt = (; gs, bs),
            reference_bus = Int(ccall((:pio_ref_bus_index, _lib()), Int64, (Ptr{Cvoid},), p)),
            n_components = Int(ccall((:pio_n_islands, _lib()), Csize_t, (Ptr{Cvoid},), p)),
            is_radial = ccall((:pio_is_radial, _lib()), Cint, (Ptr{Cvoid},), p) != 0,
        )
    end
end

"""
    to_dense(net::BalancedNetwork) -> NamedTuple
    to_dense(path; from=nothing) -> NamedTuple

Pull a case's numeric tables as dense typed arrays straight from the C ABI,
skipping the JSON transport (the fast path for matrix assembly). Takes a parsed
[`BalancedNetwork`](@ref) (via its live handle) or a `path` to parse first (which never
builds the JSON view). Fields:

- `n`, `m`, `ng` — bus / branch / generator counts.
- `base_mva` — system base.
- `bus_ids::Vector{Int64}` — 1-based bus ids in dense order; row `k` of every
  per-bus table is bus `bus_ids[k]`. Invert it to map a 1-based endpoint id to a
  dense row.
- `branch` — NamedTuple of `from, to` (1-based bus ids), `r, x, b, tap, shift`
  (raw MATPOWER units, degrees, total charging, raw tap), and `in_service::Vector{UInt8}`.
- `gen` — NamedTuple of `bus` (1-based id, one row per machine), `pg, pmax, pmin`
  (MW), `in_service`.
- `demand`, `shunt` — NamedTuples of per-bus `(pd, qd)` and `(gs, bs)` in dense order.
- `reference_bus::Int` — dense 0-based index *into `bus_ids`* of the single
  reference bus (not a 1-based id), or `-1` when there is no unique reference
  (none, or several).
- `n_components::Int`, `is_radial::Bool` — connectivity of the in-service topology.

For the rich, lossless element tables (costs, extras, storage, HVDC) use the
accessors on a [`parse_file`](@ref) `BalancedNetwork`; for self-describing columnar export
use [`to_arrow`](@ref).
"""
to_dense(net::BalancedNetwork) = _dense_from_handle(_live_handle(net, "to_dense"))
function to_dense(path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    try
        return _dense_from_handle(h)
    finally
        finalize(h)  # buffers are copied out; free the handle now rather than at GC
    end
end

# --- ecosystem adapter surface -----------------------------------------

_json_plain(x) = x
_json_plain(x::JSON3.Array) = [_json_plain(v) for v in x]
_json_plain(x::JSON3.Object) =
    Dict(String(k) => _json_plain(getproperty(x, k)) for k in keys(x))

_has(obj, key::Symbol) = key in keys(obj)
_get(obj, key::Symbol, default) = _has(obj, key) ? getproperty(obj, key) : default

"""
    to_powermodels(net::BalancedNetwork) -> Dict{String,Any}

Convert a parsed network to a PowerModels network data dictionary through the
PowerIO writer. This is the post-parse network data shape PowerModels.jl consumes.
"""
function to_powermodels(net::BalancedNetwork)
    text, _ = to_format(net, "powermodels-json")
    return _json_plain(JSON3.read(text))
end

"""
    from_powermodels(data) -> BalancedNetwork

Build a PowerIO [`BalancedNetwork`](@ref) from PowerModels network data. `data` may be a
Julia dictionary / NamedTuple or a JSON string.
"""
from_powermodels(data) = parse_str(JSON3.write(data), "powermodels-json")
from_powermodels(data::AbstractString) = parse_str(data, "powermodels-json")

function _powerdata_real(x, ::Type{T}, element::AbstractString,
                         field::Symbol) where {T<:Real}
    x === nothing &&
        throw(ArgumentError("PowerIO.to_powerdata: $element has missing field `$field`"))
    y = try
        T(x)
    catch err
        msg = sprint(showerror, err)
        throw(ArgumentError("PowerIO.to_powerdata: $element has invalid field `$field`: $msg"))
    end
    isfinite(y) ||
        throw(ArgumentError("PowerIO.to_powerdata: $element has non-finite field `$field`"))
    return y
end

function _quadratic_cost_coeffs(coeffs::Vector{T}, base::T,
                                normalized::Bool) where {T<:Real}
    scaled = copy(coeffs)
    if !normalized
        k = length(scaled)
        for i in eachindex(scaled)
            scaled[i] *= base^(k - i)
        end
    end
    while length(scaled) > 3 && iszero(first(scaled))
        popfirst!(scaled)
    end
    length(scaled) > 3 &&
        throw(ArgumentError("PowerIO.to_powerdata: polynomial generator cost cannot fit PowerData quadratic cost"))

    vals = [zero(T), zero(T), zero(T)]
    offset = 3 - length(scaled)
    for (i, c) in enumerate(scaled)
        vals[offset + i] = c
    end
    return vals
end

function _cost_tuple(g, ::Type{T}, base::T; normalized::Bool=false) where {T<:Real}
    cost = _get(g, :cost, nothing)
    cost === nothing && return (false, zero(T), zero(T), 0, (zero(T), zero(T), zero(T)))
    coeffs = [_powerdata_real(c, T, "generator cost", :coeffs)
              for c in collect(cost.coeffs)]
    model = Int(cost.model)
    n = Int(cost.ncost)
    if model == 2
        limit = min(n, length(coeffs))
        trimmed = limit == 0 ? T[] : coeffs[1:limit]
        vals = _quadratic_cost_coeffs(trimmed, base, normalized)
        return (true,
                _powerdata_real(cost.startup, T, "generator cost", :startup),
                _powerdata_real(cost.shutdown, T, "generator cost", :shutdown),
                3, (vals[1], vals[2], vals[3]))
    else
        limit = model == 1 ? min(2 * n, length(coeffs)) : length(coeffs)
        trimmed = limit == 0 ? T[] : coeffs[1:limit]
        vals = [zero(T), zero(T), zero(T)]
        for i in 1:min(3, length(trimmed))
            vals[i] = trimmed[i]
        end
    end
    return (model == 2,
            _powerdata_real(cost.startup, T, "generator cost", :startup),
            _powerdata_real(cost.shutdown, T, "generator cost", :shutdown),
            n, (vals[1], vals[2], vals[3]))
end

function _branch_coeffs(r::T, x::T, b_fr::T, b_to::T, g_fr::T, g_to::T,
                        tap::T, shift::T) where {T<:Real}
    y = iszero(r) && iszero(x) ? zero(Complex{T}) : inv(complex(r, x))
    isfinite(real(y)) && isfinite(imag(y)) || (y = zero(Complex{T}))
    g = real(y)
    b = imag(y)
    tap_eff = isapprox(tap, zero(T)) ? one(T) : tap
    tr = tap_eff * cos(shift)
    ti = tap_eff * sin(shift)
    ttm = tr^2 + ti^2
    return (
        (-g * tr - b * ti) / ttm,
        (-b * tr + g * ti) / ttm,
        (-g * tr + b * ti) / ttm,
        (-b * tr - g * ti) / ttm,
        (g + g_fr) / ttm,
        (b + b_fr) / ttm,
        g + g_to,
        b + b_to,
    )
end

function _to_powerdata_normalized(net::BalancedNetwork, ::Type{T}) where {T<:Real}
    base = _powerdata_real(base_mva(net), T, "network", :base_mva)
    raw_buses = collect(buses(net))
    kept_ids = [Int(b.id) for b in raw_buses]
    id_to_idx = Dict(id => i for (i, id) in enumerate(kept_ids))

    pd = zeros(T, length(kept_ids))
    qd = zeros(T, length(kept_ids))
    for (row, l) in enumerate(loads(net))
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        pd[idx] += _powerdata_real(l.p, T, "load $row", :p)
        qd[idx] += _powerdata_real(l.q, T, "load $row", :q)
    end
    gs = zeros(T, length(kept_ids))
    bs = zeros(T, length(kept_ids))
    for (row, s) in enumerate(shunts(net))
        idx = get(id_to_idx, Int(s.bus), 0)
        idx == 0 && continue
        gs[idx] += _powerdata_real(s.g, T, "shunt $row", :g)
        bs[idx] += _powerdata_real(s.b, T, "shunt $row", :b)
    end

    bus_rows = NamedTuple[]
    for b in raw_buses
        id = Int(b.id)
        i = id_to_idx[id]
        push!(bus_rows, (;
            i,
            bus_i = id,
            type = bus_type_code(String(b.kind)),
            pd = pd[i],
            qd = qd[i],
            gs = gs[i],
            bs = bs[i],
            area = Int(b.area),
            vm = _powerdata_real(b.vm, T, "bus $id", :vm),
            va = _powerdata_real(b.va, T, "bus $id", :va),
            baseKV = _powerdata_real(b.base_kv, T, "bus $id", :base_kv),
            zone = Int(b.zone),
            vmax = _powerdata_real(b.vmax, T, "bus $id", :vmax),
            vmin = _powerdata_real(b.vmin, T, "bus $id", :vmin),
        ))
    end

    gen_rows = NamedTuple[]
    for (row, g) in enumerate(generators(net))
        idx = get(id_to_idx, Int(g.bus), 0)
        idx == 0 && continue
        model_poly, startup, shutdown, ncost, c =
            _cost_tuple(g, T, base; normalized=true)
        status = Bool(_get(g, :in_service, true))
        push!(gen_rows, (;
            i = length(gen_rows) + 1,
            bus = idx,
            pg = _powerdata_real(g.pg, T, "generator $row", :pg),
            qg = _powerdata_real(g.qg, T, "generator $row", :qg),
            qmax = _powerdata_real(g.qmax, T, "generator $row", :qmax),
            qmin = _powerdata_real(g.qmin, T, "generator $row", :qmin),
            vg = _powerdata_real(g.vg, T, "generator $row", :vg),
            mbase = _powerdata_real(g.mbase, T, "generator $row", :mbase),
            status = Int(status),
            pmax = _powerdata_real(g.pmax, T, "generator $row", :pmax),
            pmin = _powerdata_real(g.pmin, T, "generator $row", :pmin),
            model_poly,
            startup,
            shutdown,
            n = ncost,
            c,
        ))
    end

    kept_branches = Any[]
    for br in branches(net)
        f = get(id_to_idx, Int(br.from), 0)
        t = get(id_to_idx, Int(br.to), 0)
        (f == 0 || t == 0) && continue
        push!(kept_branches, br)
    end
    m = length(kept_branches)
    branch_rows = NamedTuple[]
    for (i, br) in enumerate(kept_branches)
        label = "branch $i"
        f = id_to_idx[Int(br.from)]
        t = id_to_idx[Int(br.to)]
        tap_raw = _powerdata_real(br.tap, T, label, :tap)
        tap = isapprox(tap_raw, zero(T)) ? one(T) : tap_raw
        shift = _powerdata_real(br.shift, T, label, :shift)
        b = _powerdata_real(br.b, T, label, :b)
        b_fr = b / T(2)
        b_to = b / T(2)
        g_fr = zero(T)
        g_to = zero(T)
        r = _powerdata_real(br.r, T, label, :br_r)
        x = _powerdata_real(br.x, T, label, :br_x)
        c1, c2, c3, c4, c5, c6, c7, c8 =
            _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
        push!(branch_rows, (;
            i,
            f_bus = f,
            t_bus = t,
            br_r = r,
            br_x = x,
            b_fr,
            b_to,
            g_fr,
            g_to,
            rate_a = _powerdata_real(br.rate_a, T, label, :rate_a),
            rate_b = _powerdata_real(br.rate_b, T, label, :rate_b),
            rate_c = _powerdata_real(br.rate_c, T, label, :rate_c),
            tap,
            shift,
            status = Int(Bool(_get(br, :in_service, true))),
            angmin = _powerdata_real(br.angmin, T, label, :angmin),
            angmax = _powerdata_real(br.angmax, T, label, :angmax),
            f_idx = i,
            t_idx = i + m,
            c1, c2, c3, c4, c5, c6, c7, c8,
        ))
    end
    arc_rows = NamedTuple[]
    for (i, br) in enumerate(branch_rows)
        push!(arc_rows, (; i, bus = br.f_bus, rate_a = br.rate_a))
    end
    for (i, br) in enumerate(branch_rows)
        push!(arc_rows, (; i = i + m, bus = br.t_bus, rate_a = br.rate_a))
    end

    storage_rows = NamedTuple[]
    for (row, st) in enumerate(storage(net))
        push!(storage_rows, (;
            i = length(storage_rows) + 1,
            storage_bus = Int(st.bus),
            Pexts = _powerdata_real(st.ps, T, "storage $row", :ps),
            Qexts = _powerdata_real(st.qs, T, "storage $row", :qs),
            energy = _powerdata_real(st.energy, T, "storage $row", :energy),
            energy_rating = _powerdata_real(st.energy_rating, T, "storage $row", :energy_rating),
            charge_rating = _powerdata_real(st.charge_rating, T, "storage $row", :charge_rating),
            discharge_rating = _powerdata_real(st.discharge_rating, T, "storage $row", :discharge_rating),
            charge_efficiency = _powerdata_real(st.charge_efficiency, T, "storage $row", :charge_efficiency),
            discharge_efficiency = _powerdata_real(st.discharge_efficiency, T, "storage $row", :discharge_efficiency),
            thermal_rating = _powerdata_real(st.thermal_rating, T, "storage $row", :thermal_rating),
            qmin = _powerdata_real(st.qmin, T, "storage $row", :qmin),
            qmax = _powerdata_real(st.qmax, T, "storage $row", :qmax),
            Zr = _powerdata_real(st.r, T, "storage $row", :r),
            Zim = _powerdata_real(st.x, T, "storage $row", :x),
            p_loss = _powerdata_real(st.p_loss, T, "storage $row", :p_loss),
            q_loss = _powerdata_real(st.q_loss, T, "storage $row", :q_loss),
            status = Int(Bool(_get(st, :in_service, true))),
        ))
    end

    return (;
        version = "2",
        baseMVA = base,
        bus = bus_rows,
        gen = gen_rows,
        branch = branch_rows,
        arc = arc_rows,
        storage = storage_rows,
    )
end

"""
    to_powerdata(net; filtered=true, T=Float64) -> NamedTuple
    to_powerdata(path; from=nothing, filtered=true, T=Float64) -> NamedTuple

Return a NamedTuple in ExaPowerIO's `PowerData` shape: `version`, `baseMVA`, `bus`,
`gen`, `branch`, `arc`, and `storage`. Rows use the field names ExaModelsPower
reads. With the default `filtered=true`, values are derived from
[`to_normalized`](@ref): `bus_i` preserves the source bus id, powers are per unit,
branch angle fields are radians, and branch/generator bus references are indices
into the bus vector.
"""
function to_powerdata(net::BalancedNetwork; filtered::Bool=true, T::Type{<:Real}=Float64)
    if filtered
        norm = source_format(net) == "Normalized" ? net : to_normalized(net)
        return _to_powerdata_normalized(norm, T)
    end

    base = T(base_mva(net))
    raw_buses = collect(buses(net))
    keep_bus = Dict{Int,Bool}()
    for b in raw_buses
        keep_bus[Int(b.id)] = !filtered || String(b.kind) != "ISOLATED"
    end
    kept_ids = [Int(b.id) for b in raw_buses if keep_bus[Int(b.id)]]
    id_to_idx = Dict(id => i for (i, id) in enumerate(kept_ids))

    pd = zeros(T, length(kept_ids))
    qd = zeros(T, length(kept_ids))
    for l in loads(net)
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        if !filtered || Bool(_get(l, :in_service, true))
            pd[idx] += T(l.p) / base
            qd[idx] += T(l.q) / base
        end
    end
    gs = zeros(T, length(kept_ids))
    bs = zeros(T, length(kept_ids))
    for s in shunts(net)
        idx = get(id_to_idx, Int(s.bus), 0)
        idx == 0 && continue
        if !filtered || Bool(_get(s, :in_service, true))
            gs[idx] += T(s.g) / base
            bs[idx] += T(s.b) / base
        end
    end

    bus_rows = NamedTuple[]
    for b in raw_buses
        id = Int(b.id)
        keep_bus[id] || continue
        i = id_to_idx[id]
        push!(bus_rows, (;
            i,
            bus_i = id,
            type = bus_type_code(String(b.kind)),
            pd = pd[i],
            qd = qd[i],
            gs = gs[i],
            bs = bs[i],
            area = Int(b.area),
            vm = T(b.vm),
            va = T(b.va),
            baseKV = T(b.base_kv),
            zone = Int(b.zone),
            vmax = T(b.vmax),
            vmin = T(b.vmin),
        ))
    end

    gen_rows = NamedTuple[]
    has_gen = falses(length(bus_rows))
    biggest_gen_bus = 0
    biggest_gen_pmax = typemin(T)
    for (row, g) in enumerate(generators(net))
        idx = get(id_to_idx, Int(g.bus), 0)
        idx == 0 && continue
        status = Bool(g.in_service)
        filtered && !status && continue
        model_poly, startup, shutdown, ncost, c =
            _cost_tuple(g, T, base; normalized=false)
        pmax = T(g.pmax) / base
        push!(gen_rows, (;
            i = length(gen_rows) + 1,
            bus = idx,
            pg = T(g.pg) / base,
            qg = T(g.qg) / base,
            qmax = T(g.qmax) / base,
            qmin = T(g.qmin) / base,
            vg = T(g.vg),
            mbase = T(g.mbase),
            status = Int(status),
            pmax,
            pmin = T(g.pmin) / base,
            model_poly,
            startup,
            shutdown,
            n = ncost,
            c,
        ))
        if status
            has_gen[idx] = true
            if pmax > biggest_gen_pmax
                biggest_gen_pmax = pmax
                biggest_gen_bus = idx
            end
        end
    end

    for i in eachindex(bus_rows)
        typ = bus_rows[i].type
        if has_gen[i] && typ == 1
            bus_rows[i] = merge(bus_rows[i], (; type = 2))
        elseif !has_gen[i] && (typ == 2 || typ == 3)
            bus_rows[i] = merge(bus_rows[i], (; type = 1))
        end
    end
    if !any(row.type == 3 for row in bus_rows) && biggest_gen_bus > 0
        bus_rows[biggest_gen_bus] = merge(bus_rows[biggest_gen_bus], (; type = 3))
    end

    kept_branches = Any[]
    for br in branches(net)
        f = get(id_to_idx, Int(br.from), 0)
        t = get(id_to_idx, Int(br.to), 0)
        (f == 0 || t == 0) && continue
        status = Bool(br.in_service)
        filtered && !status && continue
        push!(kept_branches, br)
    end
    m = length(kept_branches)
    branch_rows = NamedTuple[]
    for (i, br) in enumerate(kept_branches)
        f = id_to_idx[Int(br.from)]
        t = id_to_idx[Int(br.to)]
        label = "branch $i"
        tap_raw = _powerdata_real(br.tap, T, label, :tap)
        tap = isapprox(tap_raw, zero(T)) ? one(T) : tap_raw
        shift = _powerdata_real(br.shift, T, label, :shift) / T(180) * T(pi)
        b = _powerdata_real(br.b, T, label, :b)
        b_fr = b / T(2)
        b_to = b / T(2)
        g_fr = zero(T)
        g_to = zero(T)
        r = _powerdata_real(br.r, T, label, :br_r)
        x = _powerdata_real(br.x, T, label, :br_x)
        c1, c2, c3, c4, c5, c6, c7, c8 =
            _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
        push!(branch_rows, (;
            i,
            f_bus = f,
            t_bus = t,
            br_r = r,
            br_x = x,
            b_fr,
            b_to,
            g_fr,
            g_to,
            rate_a = _powerdata_real(br.rate_a, T, label, :rate_a) / base,
            rate_b = _powerdata_real(br.rate_b, T, label, :rate_b) / base,
            rate_c = _powerdata_real(br.rate_c, T, label, :rate_c) / base,
            tap,
            shift,
            status = Int(Bool(br.in_service)),
            angmin = _powerdata_real(br.angmin, T, label, :angmin) / T(180) * T(pi),
            angmax = _powerdata_real(br.angmax, T, label, :angmax) / T(180) * T(pi),
            f_idx = i,
            t_idx = i + m,
            c1, c2, c3, c4, c5, c6, c7, c8,
        ))
    end
    arc_rows = NamedTuple[]
    for (i, br) in enumerate(branch_rows)
        push!(arc_rows, (; i, bus = br.f_bus, rate_a = br.rate_a))
    end
    for (i, br) in enumerate(branch_rows)
        push!(arc_rows, (; i = i + m, bus = br.t_bus, rate_a = br.rate_a))
    end

    storage_rows = NamedTuple[]
    for st in storage(net)
        status = Bool(st.in_service)
        push!(storage_rows, (;
            i = length(storage_rows) + 1,
            storage_bus = Int(st.bus),
            Pexts = T(st.ps),
            Qexts = T(st.qs),
            energy = T(st.energy) / base,
            energy_rating = T(st.energy_rating) / base,
            charge_rating = T(st.charge_rating) / base,
            discharge_rating = T(st.discharge_rating) / base,
            charge_efficiency = T(st.charge_efficiency),
            discharge_efficiency = T(st.discharge_efficiency),
            thermal_rating = T(st.thermal_rating) / base,
            qmin = T(st.qmin) / base,
            qmax = T(st.qmax) / base,
            Zr = T(st.r),
            Zim = T(st.x),
            p_loss = T(st.p_loss),
            q_loss = T(st.q_loss),
            status = Int(status),
        ))
    end

    return (;
        version = "2",
        baseMVA = base,
        bus = bus_rows,
        gen = gen_rows,
        branch = branch_rows,
        arc = arc_rows,
        storage = storage_rows,
    )
end

to_powerdata(path::AbstractString; from=nothing, filtered::Bool=true,
             T::Type{<:Real}=Float64) =
    to_powerdata(parse_file(path; from=from); filtered=filtered, T=T)

"""
    parse_ac_power_data(input; from=nothing, filtered=true, T=Float64) -> NamedTuple

Return the NamedTuple shape consumed by ExaModelsPower's `build_polar_opf`,
`build_rect_opf`, and `build_dcopf`. `input` may be a [`BalancedNetwork`](@ref) or a path.
"""
function parse_ac_power_data(input; from=nothing, filtered::Bool=true,
                             T::Type{<:Real}=Float64)
    pd = input isa BalancedNetwork ? to_powerdata(input; filtered=filtered, T=T) :
         to_powerdata(String(input); from=from, filtered=filtered, T=T)
    empty_storage = NamedTuple{(:i,),Tuple{Int64}}[]
    storage_rows = isempty(pd.storage) ? empty_storage : pd.storage
    return (;
        baseMVA = [pd.baseMVA],
        bus = pd.bus,
        gen = pd.gen,
        arc = pd.arc,
        branch = pd.branch,
        storage = storage_rows,
        ref_buses = [i for i in 1:length(pd.bus) if pd.bus[i].type == 3],
        vmax = [b.vmax for b in pd.bus],
        vmin = [b.vmin for b in pd.bus],
        pmax = [g.pmax for g in pd.gen],
        pmin = [g.pmin for g in pd.gen],
        qmax = [g.qmax for g in pd.gen],
        qmin = [g.qmin for g in pd.gen],
        angmax = [br.angmax for br in pd.branch],
        angmin = [br.angmin for br in pd.branch],
        rate_a = [a.rate_a for a in pd.arc],
        vm0 = [b.vm for b in pd.bus],
        va0 = [b.va for b in pd.bus],
        pg0 = [g.pg for g in pd.gen],
        qg0 = [g.qg for g in pd.gen],
        pdmax = isempty(pd.storage) ? empty_storage : [s.charge_rating for s in pd.storage],
        pcmax = isempty(pd.storage) ? empty_storage : [s.discharge_rating for s in pd.storage],
        srating = isempty(pd.storage) ? empty_storage : [s.thermal_rating for s in pd.storage],
        emax = isempty(pd.storage) ? empty_storage : [s.energy_rating for s in pd.storage],
    )
end

include("arrow.jl")
include("gridfm.jl")
include("package.jl")
include("dist.jl")

end # module
