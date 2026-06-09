"""
    PowerIO

Julia bindings for the PowerIO Rust core: parse MATPOWER / PSS/E / PowerWorld /
PowerModels JSON / EGRET JSON case files, convert between any pair (byte-exact on a
same-format round-trip, maximal-fidelity otherwise), and materialize an immutable
`Network`, all through the `powerio-capi` C ABI.

Parse once with [`parse_case`](@ref) → [`Network`](@ref), then read it three ways,
all over the same C ABI:

- the rich, lossless element tables via the JSON transport (every field + extras,
  costs, storage, HVDC) — the accessors and [`to_json`](@ref).
- [`to_dense`](@ref): the numeric tables as dense typed arrays for matrix assembly,
  straight from the C ABI extractors — no JSON.
- [`to_arrow`](@ref): one table zero-copy over the Arrow C Data Interface.

[`to_normalized`](@ref) derives a per-unit / radian / filtered / reindexed copy, and
[`to_matpower`](@ref) / [`convert_case`](@ref) serialize back out.

At first use the binding checks the library's ABI version (`pio_abi_version`)
against the version it targets ([`PIO_ABI_VERSION`]) and refuses a stale or
mismatched library with a directed error.

During development the C library is wired through a configurable path (see
[`set_library!`](@ref)); for the public release it ships as a self-hosted, lazy
artifact (`Artifacts.toml`), so users get the binary with no Rust toolchain. A
Yggdrasil `PowerIO_jll` is a later, non-blocking swap. See the README for the
milestone plan.
"""
module PowerIO

using JSON3
using LazyArtifacts
import Libdl

export Network, parse_case, convert_case, to_normalized, to_json, to_dense, to_matpower, to_arrow, ArrowTable

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

const PIO_ABI_VERSION = UInt32(1)
const _ABI_OK = Ref{Bool}(false)

"""
    abi_version() -> UInt32

The ABI version the resolved C library was built with (see `pio_abi_version`).
Compared against [`PIO_ABI_VERSION`], the version this binding targets.
"""
abi_version() = ccall((:pio_abi_version, _lib()), UInt32, ())

"""
    library_version() -> String

The `powerio-capi` crate version string the resolved library reports (e.g.
`"0.1.0"`). Informational; [`abi_version`] is the compatibility check.
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
        error("PowerIO: the C ABI at \"$(_lib())\" has no pio_abi_version — it predates " *
              "the versioned ABI. Rebuild powerio-capi (`cargo build -p powerio-capi --release` " *
              "in a sibling powerio checkout). Underlying: $e")
    end
    got == PIO_ABI_VERSION || error(
        "PowerIO: C ABI version mismatch — the library reports ABI $got, this PowerIO.jl " *
        "targets ABI $(PIO_ABI_VERSION). Rebuild powerio-capi from a matching commit, or " *
        "update PowerIO.jl.")
    _ABI_OK[] = true
    return
end

"""
    library_available() -> Bool

True if the C ABI library resolves and is ABI-compatible with this binding (see
[`abi_version`]). Tests that need the library skip when this is false.
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

# Directed error for when the ccall itself fails to dispatch — a missing library or
# undefined symbol — instead of a raw ccall fault far from the resolution site.
_lib_call_error(e) = error(
    "PowerIO: could not call the C ABI at \"$(_lib())\" — build it " *
    "(`cargo build -p powerio-capi --release` in a sibling powerio checkout) " *
    "or set POWERIO_CAPI / call `set_library!`. Underlying: $e")

function _parse_handle(path::AbstractString; from=nothing)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    fromc = from === nothing ? C_NULL : String(from)
    ptr = try
        ccall((:pio_parse, _lib()), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              path, fromc, err, length(err))
    catch e
        _lib_call_error(e)
    end
    ptr == C_NULL && error("PowerIO.parse_case: " * _cstr(err))
    return CaseHandle(ptr)
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
Raw MATPOWER units and 1-based bus ids, mirroring `powerio`'s `Network`: buses,
loads, shunts, branches, generators, storage, and hvdc tables plus `base_mva`,
`name`, and `source_format` (the format it was read from). For now the tables are
the parsed JSON (`net.data`); the fully typed struct mirroring
`powerio/src/network.rs` is v0.1.0 (see issues).

A `Network` from [`parse_case`](@ref) also keeps its live Rust [`CaseHandle`](@ref)
(`net.handle`), so the `to_*` transforms ([`to_normalized`](@ref), [`to_dense`](@ref),
[`to_matpower`](@ref), [`to_arrow`](@ref)) work straight off it. The handle's
finalizer frees the Rust case once the `Network` is unreachable. A `Network` built
straight from JSON has `handle === nothing`; only [`to_json`](@ref) works on it.
"""
struct Network
    data::JSON3.Object
    handle::Union{CaseHandle,Nothing}
end
Network(data::JSON3.Object) = Network(data, nothing)

"""
    parse_case(path; from=nothing) -> Network
    parse_case(text::AbstractString, format::AbstractString) -> Network
    parse_case(io::IO, format::AbstractString) -> Network

Parse a case into a [`Network`].

From a file `path` the format is inferred from the extension unless `from` is given
(needed to tell EGRET and PowerModels `.json` apart). From in-memory `text`, or the
full contents of an `io`, the `format` is required and passed positionally: a second
positional argument means the first is case *content*, not a path. To hint the
format of a file, use the `from=` keyword — `parse_case("c.m", "matpower")` parses
`"c.m"` as MATPOWER text, while `parse_case("c.m"; from="matpower")` reads the file.

Accepted format tokens (case-insensitive): `"matpower"`/`"m"`, `"powermodels-json"`/
`"powermodels"`/`"pm"`, `"egret-json"`/`"egret"`, `"psse"`/`"raw"`,
`"powerworld"`/`"aux"`.
"""
function parse_case(path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    return Network(JSON3.read(_to_json(h)), h)
end
function parse_case(text::AbstractString, format::AbstractString)
    h = _parse_handle_str(text, format)
    return Network(JSON3.read(_to_json(h)), h)
end
parse_case(io::IO, format::AbstractString) = parse_case(read(io, String), format)

# The live Rust handle a Network-first transform needs; a Network built straight
# from JSON has none, so name the function that needs it.
function _live_handle(net::Network, fname::AbstractString)
    net.handle === nothing && error(
        "PowerIO.$fname: this Network has no live case handle (produce it with parse_case).")
    return net.handle
end

# Derive a normalized handle from a live one via `pio_to_normalized` (a read-only
# borrow of the source case, so the source handle stays valid).
function _normalize_handle(h::CaseHandle)
    err = zeros(UInt8, _ERRLEN)
    ptr = ccall((:pio_to_normalized, _lib()), Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    ptr == C_NULL && error("PowerIO.to_normalized: " * _cstr(err))
    return CaseHandle(ptr)
end

"""
    to_normalized(net::Network) -> Network

A computation-ready copy of `net`: per unit (powers ÷ `base_mva`), angles in
radians, transformer tap `0 → 1`, out-of-service and ISOLATED elements dropped,
buses reindexed to a dense 1-based id space, and bus types inferred (a bus with a
surviving generator keeps `REF` if the source marked it so, else becomes `PV`; a
generator-less bus becomes `PQ`). `source_format` of the result is `"Normalized"`.

Needs `net`'s live Rust handle (from [`parse_case`](@ref)). Errors if `base_mva` is
not positive or no reference bus can be established.
"""
function to_normalized(net::Network)
    hn = _normalize_handle(_live_handle(net, "to_normalized"))
    return Network(JSON3.read(_to_json(hn)), hn)
end

"""
    to_json(net::Network) -> String

Serialize `net` to the C ABI's JSON transport — the same text [`parse_case`](@ref)
reads back. Uses the live handle when present, else the cached `net.data`.
"""
to_json(net::Network) = net.handle === nothing ? JSON3.write(net.data) : _to_json(net.handle)

# Serialize a live handle to MATPOWER `.m` text. `pio_write_matpower` has no error
# buffer (see powerio.h); it returns NULL on failure.
function _matpower_from_handle(p::Ptr{Cvoid})
    s = ccall((:pio_write_matpower, _lib()), Cstring, (Ptr{Cvoid},), p)
    s == C_NULL && error("PowerIO.to_matpower: failed to serialize the case")
    out = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return out
end

"""
    to_matpower(net::Network) -> String
    to_matpower(path; from=nothing) -> String

Serialize a case to MATPOWER `.m` text — byte-exact when the input was MATPOWER.
Takes a parsed [`Network`](@ref) (via its live handle) or a `path` to parse first.
"""
to_matpower(net::Network) = _matpower_from_handle(_live_handle(net, "to_matpower").ptr)
function to_matpower(path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    try
        return _matpower_from_handle(h.ptr)
    finally
        finalize(h)
    end
end

"""
    convert_case(path, to; from=nothing) -> (text, warnings)

Convert `path` to format `to`. All five formats read and write, so any pair
converts. A same-format conversion is byte-exact; a cross-format one is
maximal-fidelity and reports whatever the target can't carry in `warnings`. Tokens
(case-insensitive): `"matpower"`/`"m"`, `"powermodels-json"`/`"powermodels"`/`"pm"`,
`"egret-json"`/`"egret"`, `"psse"`/`"raw"`, `"powerworld"`/`"aux"`. `from` overrides
extension inference (needed to tell EGRET and PowerModels `.json` apart).
"""
function convert_case(path::AbstractString, to::AbstractString; from=nothing)
    _ensure_compatible()
    warn = zeros(UInt8, _ERRLEN)
    err = zeros(UInt8, _ERRLEN)
    # Pass the format hint as a `String` (ccall roots it) or `C_NULL` for inference.
    fromc = from === nothing ? C_NULL : String(from)
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
#   bus:     id, kind ∈ {"PQ","PV","REF","ISOLATED"}, vm, va (deg), base_kv,
#            vmax, vmin, area, zone, name, extras
#   gen:     bus, pg, qg, pmax, pmin, qmax, qmin, vg, mbase, in_service,
#            cost (`nothing`, or {model, startup, shutdown, ncost, coeffs}),
#            caps (ordered 11-element nullable array
#            [pc1, pc2, qc1min, qc1max, qc2min, qc2max, ramp_agc, ramp_10,
#            ramp_30, ramp_q, apf]; these lived in `extras` in older cores)
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
"First-class storage units; empty unless the source carries them (PowerModels, EGRET)."
storage(net::Network) = net.data.storage
"Two-terminal HVDC lines (MATPOWER `dcline`); empty unless the source carries them."
hvdc(net::Network) = net.data.hvdc

"""
    n_gens(net) -> Int

Number of generator rows (one per machine; `bus` repeats). Matches `pio_n_gens`:
every row, not in-service-filtered.
"""
n_gens(net::Network) = length(net.data.generators)

"""
    source_format(net) -> String

The format the case was read from, verbatim from the Rust `SourceFormat` enum:
one of `"Matpower"`, `"PowerModelsJson"`, `"EgretJson"`, `"Psse"`, `"PowerWorld"`,
`"InMemory"`, `"Normalized"` (the last is the output of [`to_normalized`](@ref)).
"""
source_format(net::Network) = String(net.data.source_format)

"""
    reference_bus_id(net) -> Union{Int,Nothing}

The 1-based id of the reference (slack) bus, or `nothing` unless exactly one bus
has `kind == "REF"`. This mirrors the "exactly one" rule of the C ABI's
`pio_reference_bus` (which returns a dense 0-based index, not an id), but returns
the 1-based id space the other accessors use.
"""
function reference_bus_id(net::Network)
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

# --- dense numeric surface ----------------------------------------------
#
# The JSON transport above is the rich, lossless view (every field + extras). For
# the matrix-assembly path a consumer wants the numeric tables as dense typed
# arrays without parsing JSON: the C ABI fills caller-allocated buffers
# (`pio_bus_ids` / `pio_branches` / `pio_gens` / `pio_nodal_*`) straight from the
# IndexCore the handle built once at parse, and answers the topology scalars
# (`pio_n_components` / `pio_is_radial` / `pio_reference_bus`) off the same core.
# Raw MATPOWER units throughout: 1-based bus ids in `bus_ids`, branch `from`/`to`,
# and gen `bus` (the same id space — invert `bus_ids` to map an endpoint to a dense
# row), degrees for `shift`, total line charging in `b`, raw `tap` (0 means 1).

function _branch_tables(p::Ptr{Cvoid}, m::Int)
    from = Vector{Int64}(undef, m); to = Vector{Int64}(undef, m)
    r = Vector{Float64}(undef, m); x = Vector{Float64}(undef, m); b = Vector{Float64}(undef, m)
    tap = Vector{Float64}(undef, m); shift = Vector{Float64}(undef, m)
    insvc = Vector{UInt8}(undef, m)
    ccall((:pio_branches, _lib()), Cvoid,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}),
          p, from, to, r, x, b, tap, shift, insvc)
    return (; from, to, r, x, b, tap, shift, in_service = insvc)
end

function _gen_tables(p::Ptr{Cvoid}, ng::Int)
    bus = Vector{Int64}(undef, ng); pg = Vector{Float64}(undef, ng)
    pmax = Vector{Float64}(undef, ng); pmin = Vector{Float64}(undef, ng)
    insvc = Vector{UInt8}(undef, ng)
    ccall((:pio_gens, _lib()), Cvoid,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}),
          p, bus, pg, pmax, pmin, insvc)
    return (; bus, pg, pmax, pmin, in_service = insvc)
end

function _nodal_demand(p::Ptr{Cvoid}, n::Int)
    pd = Vector{Float64}(undef, n); qd = Vector{Float64}(undef, n)
    ccall((:pio_nodal_demand, _lib()), Cvoid, (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}), p, pd, qd)
    return (pd, qd)
end

function _nodal_shunt(p::Ptr{Cvoid}, n::Int)
    gs = Vector{Float64}(undef, n); bs = Vector{Float64}(undef, n)
    ccall((:pio_nodal_shunt, _lib()), Cvoid, (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}), p, gs, bs)
    return (gs, bs)
end

# Dense numeric extraction off a live handle, shared by the Network and path methods.
function _dense_from_handle(p::Ptr{Cvoid})
    n = Int(ccall((:pio_n_buses, _lib()), Csize_t, (Ptr{Cvoid},), p))
    m = Int(ccall((:pio_n_branches, _lib()), Csize_t, (Ptr{Cvoid},), p))
    ng = Int(ccall((:pio_n_gens, _lib()), Csize_t, (Ptr{Cvoid},), p))
    bus_ids = Vector{Int64}(undef, n)
    ccall((:pio_bus_ids, _lib()), Cvoid, (Ptr{Cvoid}, Ptr{Int64}), p, bus_ids)
    pd, qd = _nodal_demand(p, n)
    gs, bs = _nodal_shunt(p, n)
    return (;
        n, m, ng,
        base_mva = ccall((:pio_base_mva, _lib()), Cdouble, (Ptr{Cvoid},), p),
        bus_ids,
        branch = _branch_tables(p, m),
        gen = _gen_tables(p, ng),
        demand = (; pd, qd),
        shunt = (; gs, bs),
        reference_bus = Int(ccall((:pio_reference_bus, _lib()), Cptrdiff_t, (Ptr{Cvoid},), p)),
        n_components = Int(ccall((:pio_n_components, _lib()), Csize_t, (Ptr{Cvoid},), p)),
        is_radial = ccall((:pio_is_radial, _lib()), Cint, (Ptr{Cvoid},), p) != 0,
    )
end

"""
    to_dense(net::Network) -> NamedTuple
    to_dense(path; from=nothing) -> NamedTuple

Pull a case's numeric tables as dense typed arrays straight from the C ABI — the
matrix-assembly fast path, skipping the JSON transport. Takes a parsed
[`Network`](@ref) (via its live handle) or a `path` to parse first (which never
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
- `reference_bus::Int` — dense 0-based index of the single reference bus, or `-1`.
- `n_components::Int`, `is_radial::Bool` — connectivity of the in-service topology.

For the rich, lossless element tables (costs, extras, storage, HVDC) use the
accessors on a [`parse_case`](@ref) `Network`; for zero-copy columnar export use
[`to_arrow`](@ref).
"""
to_dense(net::Network) = _dense_from_handle(_live_handle(net, "to_dense").ptr)
function to_dense(path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    try
        return _dense_from_handle(h.ptr)
    finally
        finalize(h)  # buffers are copied out; free the handle now rather than at GC
    end
end

include("arrow.jl")

end # module
