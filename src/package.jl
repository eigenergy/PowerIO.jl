# `.pio.json` network package envelope over the `pio_package_*` C ABI.
# schema_lineage.jl carries the version key and the lineage rule.

include("schema_lineage.jl")

"""
    NetworkPackage

JSON backed `.pio.json` network package envelope. A package carries one typed
payload plus model kind, producer, origin, validation, summary, diagnostics,
source maps, optional operating points, derived metadata, and lowering history.
In Julia today the envelope remains JSON backed; solver, matrix, dense, and
Arrow fast paths read live network handles, not package JSON.
"""
struct NetworkPackage
    data::JSON3.Object
end

NetworkPackage(text::AbstractString) = NetworkPackage(JSON3.read(text))
NetworkPackage(data::AbstractDict) = NetworkPackage(JSON3.read(JSON3.write(data)))
NetworkPackage(data::NamedTuple) = NetworkPackage(JSON3.read(JSON3.write(data)))

Base.getproperty(pkg::NetworkPackage, name::Symbol) =
    name === :data ? getfield(pkg, :data) : getproperty(getfield(pkg, :data), name)
Base.propertynames(pkg::NetworkPackage) = propertynames(getfield(pkg, :data))
Base.show(io::IO, pkg::NetworkPackage) =
    print(io, "NetworkPackage{", package_model_kind(pkg), "}")

const _PACKAGE_FREE_FN = Ref{Ptr{Cvoid}}(C_NULL)
const _PACKAGE_FREE_FN_LIB = Ref{String}("")
function _package_free_fn(lib::AbstractString=_lib())
    lib = String(lib)
    if _PACKAGE_FREE_FN[] == C_NULL || _PACKAGE_FREE_FN_LIB[] != lib
        _PACKAGE_FREE_FN[] = _library_symbol(lib, :pio_package_free)
        _PACKAGE_FREE_FN_LIB[] = lib
    end
    return _PACKAGE_FREE_FN[]
end

mutable struct PackageHandle
    ptr::Ptr{Cvoid}
    lib::String
    function PackageHandle(ptr::Ptr{Cvoid}, lib::AbstractString=_lib())
        ptr == C_NULL && error("PowerIO: null package handle")
        lib = String(lib)
        free = _package_free_fn(lib)
        h = new(ptr, lib)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(free, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

Base.show(io::IO, h::PackageHandle) =
    print(io, "PackageHandle(", h.ptr == C_NULL ? "freed" : "live", ")")

"""
    package_available() -> Bool

True if the resolved C library exports the `pio_package_*` API.
"""
package_available() = _exports_symbol(:pio_package_parse_str)

function _package_parse_str_handle(text::AbstractString, fname::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _package_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall(_library_symbol(lib, :pio_package_parse_str), Ptr{Cvoid},
              (Cstring, Ptr{UInt8}, Csize_t),
              String(text), err, length(err))
    catch e
        _feature_call_error(fname, "pio_package_parse_str", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return PackageHandle(ptr, lib)
end

function _package_to_json(h::PackageHandle, fname::AbstractString)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_package_to_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return _take_string(lib, s)
end

function _package_validation_json(h::PackageHandle, fname::AbstractString)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_package_validation_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return _take_string(lib, s)
end

function _package_diagnostics_json(h::PackageHandle, fname::AbstractString)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_package_diagnostics_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return _take_string(lib, s)
end

_package_operating_points_available() =
    _exports_symbol(:pio_package_operating_points_json)

_package_study_available() =
    _exports_symbol(:pio_package_study_json)

function _package_validation_handle(pkg::NetworkPackage, fname::AbstractString)
    h = _package_parse_str_handle(to_json(pkg), fname)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    rc = GC.@preserve h ccall(_library_symbol(lib, :pio_package_validate), Cint,
                              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                              h.ptr, err, length(err))
    rc == 0 || error("PowerIO.$fname: " * _cstr(err))
    return h
end

function _balanced_handle_for_package(net::BalancedNetwork)
    h = net.handle
    if h === nothing || h.ptr == C_NULL
        return _from_json_handle(to_json(net))
    end
    return h
end

"""
    to_package(net::BalancedNetwork; include_solver_metadata=false) -> NetworkPackage
    to_package(net::MulticonductorNetwork) -> NetworkPackage
    to_package(path; from=nothing, include_solver_metadata=false) -> NetworkPackage

Wrap a live PowerIO model in the `.pio.json` network package envelope. Balanced
payloads come from `pio_package_from_balanced_network`; multiconductor payloads
come from `pio_package_from_multiconductor_network`.
"""
function to_package(net::BalancedNetwork; include_solver_metadata::Bool=false)
    h = _balanced_handle_for_package(net)
    lib = getfield(h, :lib)
    _package_free_fn(lib)
    include_solver_metadata_c = include_solver_metadata ? Cint(1) : Cint(0)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        GC.@preserve h ccall(_library_symbol(lib, :pio_package_from_balanced_network), Ptr{Cvoid},
                             (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                             h.ptr, include_solver_metadata_c, err, length(err))
    catch e
        _feature_call_error("to_package", "pio_package_from_balanced_network", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.to_package: " * _cstr(err))
    pkg = PackageHandle(ptr, lib)
    return NetworkPackage(_package_to_json(pkg, "to_package"))
end

function to_package(net::MulticonductorNetwork)
    h = _live_dist_handle(net, "to_package")
    lib = getfield(h, :lib)
    _ensure_dist_compatible(lib)
    _package_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        GC.@preserve h ccall(_library_symbol(lib, :pio_package_from_multiconductor_network), Ptr{Cvoid},
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    catch e
        _feature_call_error("to_package", "pio_package_from_multiconductor_network", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.to_package(MulticonductorNetwork): " * _cstr(err))
    pkg = PackageHandle(ptr, lib)
    return NetworkPackage(_package_to_json(pkg, "to_package"))
end

function to_package(path::AbstractString; from=nothing, include_solver_metadata::Bool=false)
    net = parse_file(path; from=from)
    net isa MulticonductorNetwork || return to_package(net; include_solver_metadata=include_solver_metadata)
    include_solver_metadata && throw(ArgumentError(
        "PowerIO.to_package: include_solver_metadata applies only to balanced cases"))
    return to_package(net)
end

"""
    package_model_kind(pkg::NetworkPackage) -> Symbol

Return the explicit package `model_kind`, for example `:balanced` or
`:multiconductor`.
"""
package_model_kind(pkg::NetworkPackage) = Symbol(String(pkg.data.model_kind))

function _ensure_package_kind_consistent(pkg::NetworkPackage)
    model_kind = String(pkg.data.model_kind)
    payload_kind = String(pkg.data.model.kind)
    model_kind == payload_kind || error(
        "PowerIO.from_package: model_kind `$model_kind` does not match model.kind `$payload_kind`")
    return model_kind
end

"""
    validate_package(pkg::NetworkPackage) -> NetworkPackage

Run Rust's package semantic validation profile and return the validated package,
whose envelope carries the resulting summary. This is the verb that validates;
[`package_validation`](@ref) reads the summary already on a package without
running the profile. The two names are close enough to confuse, so reach for this
one when the package has not been validated yet.
"""
function validate_package(pkg::NetworkPackage)
    h = _package_validation_handle(pkg, "validate_package")
    return NetworkPackage(_package_to_json(h, "validate_package"))
end

"""
    package_validation(pkg::NetworkPackage)

Return the package's cached validation summary as a JSON3 object. This reads what
is already on the package; [`validate_package`](@ref) is the verb that runs the
validation profile and produces it. The two names are close enough to confuse, so
run that one first when the summary is missing or stale.
"""
function package_validation(pkg::NetworkPackage)
    h = _package_parse_str_handle(to_json(pkg), "package_validation")
    return JSON3.read(_package_validation_json(h, "package_validation"))
end

"""
    package_diagnostics(pkg::NetworkPackage)

Return the package structured diagnostics array.
"""
function package_diagnostics(pkg::NetworkPackage)
    h = _package_parse_str_handle(to_json(pkg), "package_diagnostics")
    return JSON3.read(_package_diagnostics_json(h, "package_diagnostics"))
end

function _package_operating_points_json(h::PackageHandle, fname::AbstractString)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_package_operating_points_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return _take_string(lib, s)
end

function _package_study_json(h::PackageHandle, fname::AbstractString)
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_package_study_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return _take_string(lib, s)
end

"""
    package_operating_points(pkg::NetworkPackage)

Return the package operating point series as a JSON3 value, or `nothing`.
"""
function package_operating_points(pkg::NetworkPackage)
    if !_package_operating_points_available()
        return get(pkg.data, :operating_points, nothing)
    end
    h = _package_parse_str_handle(to_json(pkg), "package_operating_points")
    value = JSON3.read(_package_operating_points_json(h, "package_operating_points"))
    return value === nothing ? nothing : value
end

"""
    set_operating_points(pkg::NetworkPackage, series) -> NetworkPackage

Return a package with its operating point series replaced from `series`
(`pio_package_set_operating_points`): JSON text, or any JSON-serializable value
in the Rust `OperatingPointSeries` layout — `time_axis` (`periods`,
`duration_hours`, optional `labels`) plus `points`, each an `index` and sparse
`updates` of `{element: {table, source_uid | row}, fields: {...}}`. `nothing`
(or JSON `null`, or an empty series) clears it. Package validation is
recomputed before returning. Read the series back with
[`package_operating_points`](@ref) and apply one point with
[`materialize_operating_point`](@ref). Needs powerio-capi v0.7 built
`--features pkg`.
"""
function set_operating_points(pkg::NetworkPackage, series)
    _require_export("set_operating_points", :pio_package_set_operating_points,
                    "powerio v0.7, `--features pkg`")
    json = series === nothing ? "null" :
           series isa AbstractString ? String(series) : JSON3.write(series)
    h = _package_parse_str_handle(to_json(pkg), "set_operating_points")
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    rc = GC.@preserve h ccall(_library_symbol(lib, :pio_package_set_operating_points), Cint,
                              (Ptr{Cvoid}, Cstring, Ptr{UInt8}, Csize_t),
                              h.ptr, json, err, length(err))
    rc == 0 || error("PowerIO.set_operating_points: " * _cstr(err))
    return NetworkPackage(_package_to_json(h, "set_operating_points"))
end

"""
    package_study(pkg::NetworkPackage)

Return the package study block as a JSON3 value, or `nothing`.
"""
function package_study(pkg::NetworkPackage)
    if !_package_study_available()
        return get(pkg.data, :study, nothing)
    end
    h = _package_parse_str_handle(to_json(pkg), "package_study")
    value = JSON3.read(_package_study_json(h, "package_study"))
    return value === nothing ? nothing : value
end

"""
    materialize_operating_point(pkg::NetworkPackage, index) -> NetworkPackage

Return a static package with operating point `index` applied. Indices are zero
based to match the `.pio.json` payload.
"""
function materialize_operating_point(pkg::NetworkPackage, index::Integer)
    _require_export("materialize_operating_point", :pio_package_materialize_operating_point,
                    "`--features pkg`")
    h = _package_parse_str_handle(to_json(pkg), "materialize_operating_point")
    lib = getfield(h, :lib)
    _package_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_package_materialize_operating_point), Ptr{Cvoid},
                               (Ptr{Cvoid}, Clonglong, Ptr{UInt8}, Csize_t),
                               h.ptr, Clonglong(index), err, length(err))
    ptr == C_NULL && error("PowerIO.materialize_operating_point: " * _cstr(err))
    materialized = PackageHandle(ptr, lib)
    return NetworkPackage(_package_to_json(materialized, "materialize_operating_point"))
end

"""
    materialize_study_commit(pkg::NetworkPackage, index) -> NetworkPackage

Return a static package with study commits `0:index` applied. Indices are zero
based to match the `.pio.json` payload.
"""
function materialize_study_commit(pkg::NetworkPackage, index::Integer)
    _require_export("materialize_study_commit", :pio_package_materialize_study_commit,
                    "`--features pkg`")
    h = _package_parse_str_handle(to_json(pkg), "materialize_study_commit")
    lib = getfield(h, :lib)
    _package_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_package_materialize_study_commit), Ptr{Cvoid},
                               (Ptr{Cvoid}, Clonglong, Ptr{UInt8}, Csize_t),
                               h.ptr, Clonglong(index), err, length(err))
    ptr == C_NULL && error("PowerIO.materialize_study_commit: " * _cstr(err))
    materialized = PackageHandle(ptr, lib)
    return NetworkPackage(_package_to_json(materialized, "materialize_study_commit"))
end

"""
    multiconductor_to_balanced_preflight(pkg; base_mva=100.0)

Return the structured readiness report for lowering a multiconductor package to
a balanced package.
"""
function multiconductor_to_balanced_preflight(pkg::NetworkPackage; base_mva::Real=100.0)
    h = _package_parse_str_handle(to_json(pkg), "multiconductor_to_balanced_preflight")
    lib = getfield(h, :lib)
    base_mva_c = Cdouble(base_mva)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_package_multiconductor_to_balanced_preflight_json), Cstring,
                             (Ptr{Cvoid}, Cdouble, Ptr{UInt8}, Csize_t),
                             h.ptr, base_mva_c, err, length(err))
    s == C_NULL && error("PowerIO.multiconductor_to_balanced_preflight: " * _cstr(err))
    return JSON3.read(_take_string(lib, s))
end

"""
    lower_multiconductor_to_balanced(pkg; base_mva=100.0) -> NetworkPackage

Lower a multiconductor package to a new balanced `.pio.json` package.
"""
function lower_multiconductor_to_balanced(pkg::NetworkPackage; base_mva::Real=100.0)
    h = _package_parse_str_handle(to_json(pkg), "lower_multiconductor_to_balanced")
    lib = getfield(h, :lib)
    _package_free_fn(lib)
    base_mva_c = Cdouble(base_mva)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_package_lower_multiconductor_to_balanced), Ptr{Cvoid},
                               (Ptr{Cvoid}, Cdouble, Ptr{UInt8}, Csize_t),
                               h.ptr, base_mva_c, err, length(err))
    ptr == C_NULL && error("PowerIO.lower_multiconductor_to_balanced: " * _cstr(err))
    lowered = PackageHandle(ptr, lib)
    return NetworkPackage(_package_to_json(lowered, "lower_multiconductor_to_balanced"))
end

# Extract an owned network handle from a parsed package handle via one of the
# payload inverses (`pio_package_to_balanced_network` /
# `pio_package_to_multiconductor_network`); shared by both from_package arms.
function _package_extract_ptr(pkg::NetworkPackage, sym::Symbol)
    h = _package_parse_str_handle(to_json(pkg), "from_package")
    lib = getfield(h, :lib)
    err = zeros(UInt8, _ERRLEN)
    # ccall needs a literal symbol, so resolve the entry point by hand; the
    # un-dlclosed handle pins the library, as in `_network_free_fn`.
    _require_export("from_package", sym, "`--features pkg`", lib)
    if sym === :pio_package_to_balanced_network
        _network_free_fn(lib)
    elseif sym === :pio_package_to_multiconductor_network
        _ensure_dist_compatible(lib)
        _dist_network_free_fn(lib)
    end
    ptr = try
        fn = _library_symbol(lib, sym)
        GC.@preserve h ccall(fn, Ptr{Cvoid},
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    catch e
        _feature_call_error("from_package", String(sym), "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.from_package: " * _cstr(err))
    return (ptr, lib)
end

"""
    from_package(pkg::NetworkPackage) -> BalancedNetwork | MulticonductorNetwork
    from_package(text::AbstractString)

Read a `.pio.json` package back into the live model its envelope declares: a
[`BalancedNetwork`](@ref) for a balanced payload, a
[`MulticonductorNetwork`](@ref) for a multiconductor one. Lowering a
multiconductor package to balanced stays explicit, through
[`lower_multiconductor_to_balanced`](@ref). A handle rebuilt from a package
retains no source text, so a same-format write is a fresh serialization, not
a byte-exact echo.
"""
function from_package(pkg::NetworkPackage)
    kind = _ensure_package_kind_consistent(pkg)
    if kind == "balanced"
        ptr, lib = _package_extract_ptr(pkg, :pio_package_to_balanced_network)
        h = BalancedNetworkHandle(ptr, lib)
        return BalancedNetwork(h)
    elseif kind == "multiconductor"
        ptr, lib = _package_extract_ptr(pkg, :pio_package_to_multiconductor_network)
        h = MulticonductorNetworkHandle(ptr, lib)
        return MulticonductorNetwork(h)
    else
        error("PowerIO.from_package: unsupported package model_kind `$kind`")
    end
end

from_package(text::AbstractString) = from_package(NetworkPackage(text))

"""
    read_package(path) -> NetworkPackage

Read a `.pio.json` package envelope from disk. Uses the C package parser when
available, with a JSON fallback so docs and pure parsing still work without a
native library.
"""
function read_package(path::AbstractString)
    if !package_available()
        return NetworkPackage(read(path, String))
    end
    lib = _lib()
    _ensure_compatible(lib)
    _package_free_fn(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall(_library_symbol(lib, :pio_package_parse_file), Ptr{Cvoid},
              (Cstring, Ptr{UInt8}, Csize_t), path, err, length(err))
    catch e
        _feature_call_error("read_package", "pio_package_parse_file", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.read_package: " * _cstr(err))
    h = PackageHandle(ptr, lib)
    return NetworkPackage(_package_to_json(h, "read_package"))
end

"""
    write_package(path, pkg_or_net; include_solver_metadata=false) -> String

Write a [`NetworkPackage`](@ref), [`BalancedNetwork`](@ref), or
[`MulticonductorNetwork`](@ref) as `.pio.json` and return `path`.
"""
function write_package(path::AbstractString, pkg::NetworkPackage)
    write(path, to_json(pkg))
    return path
end

function write_package(path::AbstractString, net::BalancedNetwork; include_solver_metadata::Bool=false)
    return write_package(path, to_package(net; include_solver_metadata=include_solver_metadata))
end

write_package(path::AbstractString, net::MulticonductorNetwork) =
    write_package(path, to_package(net))

to_json(pkg::NetworkPackage) = JSON3.write(pkg.data)
