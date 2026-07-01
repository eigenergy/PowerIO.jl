# `.pio.json` network package envelope over the `pio_package_*` C ABI.

const PIO_PACKAGE_SCHEMA_URL = "https://powerio.dev/schema/pio-package/0.1"
const PIO_PACKAGE_SCHEMA_VERSION = "0.2.0"

"""
    NetworkPackage

JSON backed `.pio.json` network package envelope. A package carries one typed
payload plus model kind, producer, origin, validation, summary, diagnostics,
source maps, optional operating points, derived metadata, and lowering history.
"""
struct NetworkPackage
    data::JSON3.Object
end

const CompilerPackage = NetworkPackage

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
function _package_free_fn()
    lib = _lib()
    if _PACKAGE_FREE_FN[] == C_NULL || _PACKAGE_FREE_FN_LIB[] != lib
        _PACKAGE_FREE_FN[] = Libdl.dlsym(Libdl.dlopen(lib), :pio_package_free)
        _PACKAGE_FREE_FN_LIB[] = lib
    end
    return _PACKAGE_FREE_FN[]
end

mutable struct PackageHandle
    ptr::Ptr{Cvoid}
    function PackageHandle(ptr::Ptr{Cvoid})
        ptr == C_NULL && error("PowerIO: null package handle")
        free = _package_free_fn()
        h = new(ptr)
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

True if the resolved C library exports the `pio_package_*` surface.
"""
package_available() = _exports_symbol(:pio_package_parse_str)

function _package_parse_str_handle(text::AbstractString, fname::AbstractString)
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_package_parse_str, _lib()), Ptr{Cvoid},
              (Cstring, Ptr{UInt8}, Csize_t),
              String(text), err, length(err))
    catch e
        _feature_call_error(fname, "pio_package_parse_str", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    return PackageHandle(ptr)
end

function _package_to_json(h::PackageHandle, fname::AbstractString)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_package_to_json, _lib()), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return text
end

function _package_validation_json(h::PackageHandle, fname::AbstractString)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_package_validation_json, _lib()), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return text
end

function _package_diagnostics_json(h::PackageHandle, fname::AbstractString)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_package_diagnostics_json, _lib()), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return text
end

function _package_validation_handle(pkg::NetworkPackage, fname::AbstractString)
    h = _package_parse_str_handle(to_json(pkg), fname)
    err = zeros(UInt8, _ERRLEN)
    rc = GC.@preserve h ccall((:pio_package_validate, _lib()), Cint,
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
    include_solver_metadata_c = include_solver_metadata ? Cint(1) : Cint(0)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        GC.@preserve h ccall((:pio_package_from_balanced_network, _lib()), Ptr{Cvoid},
                             (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                             h.ptr, include_solver_metadata_c, err, length(err))
    catch e
        _feature_call_error("to_package", "pio_package_from_balanced_network", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.to_package: " * _cstr(err))
    pkg = PackageHandle(ptr)
    return NetworkPackage(_package_to_json(pkg, "to_package"))
end

function to_package(net::MulticonductorNetwork)
    _ensure_dist_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        GC.@preserve net ccall((:pio_package_from_multiconductor_network, _lib()), Ptr{Cvoid},
                               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                               net.ptr, err, length(err))
    catch e
        _feature_call_error("to_package", "pio_package_from_multiconductor_network", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.to_package(MulticonductorNetwork): " * _cstr(err))
    pkg = PackageHandle(ptr)
    return NetworkPackage(_package_to_json(pkg, "to_package"))
end

to_package(path::AbstractString; from=nothing, include_solver_metadata::Bool=false) =
    to_package(parse_file(path; from=from); include_solver_metadata=include_solver_metadata)

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

Run Rust's package semantic validation profile and return the validated package.
"""
function validate_package(pkg::NetworkPackage)
    h = _package_validation_handle(pkg, "validate_package")
    return NetworkPackage(_package_to_json(h, "validate_package"))
end

"""
    package_validation(pkg::NetworkPackage)

Return the package validation summary as a JSON3 object.
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
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_package_operating_points_json, _lib()), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.$fname: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return text
end

"""
    package_operating_points(pkg::NetworkPackage)

Return the package operating point series as a JSON3 value, or `nothing`.
"""
function package_operating_points(pkg::NetworkPackage)
    h = _package_parse_str_handle(to_json(pkg), "package_operating_points")
    value = JSON3.read(_package_operating_points_json(h, "package_operating_points"))
    return value === nothing ? nothing : value
end

"""
    materialize_operating_point(pkg::NetworkPackage, index) -> NetworkPackage

Return a static package with operating point `index` applied. Indices are zero
based to match the `.pio.json` payload.
"""
function materialize_operating_point(pkg::NetworkPackage, index::Integer)
    h = _package_parse_str_handle(to_json(pkg), "materialize_operating_point")
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall((:pio_package_materialize_operating_point, _lib()), Ptr{Cvoid},
                               (Ptr{Cvoid}, Clonglong, Ptr{UInt8}, Csize_t),
                               h.ptr, Clonglong(index), err, length(err))
    ptr == C_NULL && error("PowerIO.materialize_operating_point: " * _cstr(err))
    materialized = PackageHandle(ptr)
    return NetworkPackage(_package_to_json(materialized, "materialize_operating_point"))
end

"""
    multiconductor_to_balanced_preflight(pkg; base_mva=100.0)

Return the structured readiness report for lowering a multiconductor package to
a balanced package.
"""
function multiconductor_to_balanced_preflight(pkg::NetworkPackage; base_mva::Real=100.0)
    h = _package_parse_str_handle(to_json(pkg), "multiconductor_to_balanced_preflight")
    base_mva_c = Cdouble(base_mva)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall((:pio_package_multiconductor_to_balanced_preflight_json, _lib()), Cstring,
                             (Ptr{Cvoid}, Cdouble, Ptr{UInt8}, Csize_t),
                             h.ptr, base_mva_c, err, length(err))
    s == C_NULL && error("PowerIO.multiconductor_to_balanced_preflight: " * _cstr(err))
    text = unsafe_string(s)
    ccall((:pio_string_free, _lib()), Cvoid, (Cstring,), s)
    return JSON3.read(text)
end

"""
    lower_multiconductor_to_balanced(pkg; base_mva=100.0) -> NetworkPackage

Lower a multiconductor package to a new balanced `.pio.json` package.
"""
function lower_multiconductor_to_balanced(pkg::NetworkPackage; base_mva::Real=100.0)
    h = _package_parse_str_handle(to_json(pkg), "lower_multiconductor_to_balanced")
    base_mva_c = Cdouble(base_mva)
    err = zeros(UInt8, _ERRLEN)
    ptr = GC.@preserve h ccall((:pio_package_lower_multiconductor_to_balanced, _lib()), Ptr{Cvoid},
                               (Ptr{Cvoid}, Cdouble, Ptr{UInt8}, Csize_t),
                               h.ptr, base_mva_c, err, length(err))
    ptr == C_NULL && error("PowerIO.lower_multiconductor_to_balanced: " * _cstr(err))
    lowered = PackageHandle(ptr)
    return NetworkPackage(_package_to_json(lowered, "lower_multiconductor_to_balanced"))
end

"""
    from_package(pkg::NetworkPackage) -> BalancedNetwork
    from_package(text::AbstractString) -> BalancedNetwork

Read a `.pio.json` package back into a live [`BalancedNetwork`](@ref). Balanced
payloads load directly; multiconductor payloads are explicitly lowered through
Rust's multiconductor to balanced pass first.
"""
function from_package(pkg::NetworkPackage)
    kind = _ensure_package_kind_consistent(pkg)
    if kind == "balanced"
        return from_json(JSON3.write(pkg.data.model.balanced_network))
    elseif kind == "multiconductor"
        return from_package(lower_multiconductor_to_balanced(pkg))
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
    _ensure_compatible()
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_package_parse_file, _lib()), Ptr{Cvoid},
              (Cstring, Ptr{UInt8}, Csize_t), path, err, length(err))
    catch e
        _feature_call_error("read_package", "pio_package_parse_file", "pkg", e)
    end
    ptr == C_NULL && error("PowerIO.read_package: " * _cstr(err))
    h = PackageHandle(ptr)
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
