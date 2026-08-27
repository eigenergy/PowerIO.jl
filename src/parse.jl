# The universal parse and its typed narrowing: defined after the network
# types so the value_type methods resolve.

"""
    as_network(m::StoredModule) -> BalancedNetwork

The module's balanced network value as an owned network handle with the
module's provenance threaded on, so a same format write still echoes the
retained source bytes. Any other value kind is refused with the kind named.
"""
function as_network(m::StoredModule)
    lib = getfield(m, :lib)
    _require_export("as_network", :pio_module_as_network, "powerio v1.0", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_as_network), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return BalancedNetwork(BalancedNetworkHandle(ptr, lib))
end

"""
    as_dist_network(m::StoredModule) -> MulticonductorNetwork

The module's multiconductor network value as an owned distribution handle,
provenance included. Any other value kind is refused with the kind named.
"""
function as_dist_network(m::StoredModule)
    lib = getfield(m, :lib)
    _require_export("as_dist_network", :pio_module_as_dist_network, "powerio v1.0", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_as_dist_network), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return MulticonductorNetwork(MulticonductorNetworkHandle(ptr, lib))
end

"""
    PowerIO.parse(source; from=nothing, value_type=nothing)

Parse one source into a [`StoredModule`](@ref) of whichever family claims
it. `source` is a filesystem path, an `IO`, or in-memory bytes (the only way
to read a binary format without a file). A source that defines a calculation
produces that calculation's typed value; `module_kind` names it.

`value_type` narrows in one call: pass [`BalancedNetwork`](@ref) or
[`MulticonductorNetwork`](@ref) to get that handle directly (provenance
threaded on, so a same format write echoes the source bytes), raising when
the parsed value is another kind. Unexported deliberately: call it as
`PowerIO.parse`, beside `Base.parse`.
"""
function parse(path::AbstractString; from=nothing, value_type=nothing)
    m = parse_module(path; format=from === nothing ? nothing : String(from))
    return _narrow(m, value_type)
end
function parse(bytes::AbstractVector{UInt8}; from=nothing, value_type=nothing)
    m = parse_module_bytes(bytes; format=from === nothing ? nothing : String(from))
    return _narrow(m, value_type)
end
parse(io::IO; kwargs...) = parse(read(io); kwargs...)

_narrow(m::StoredModule, ::Nothing) = m
_narrow(m::StoredModule, ::Type{StoredModule}) = m
_narrow(m::StoredModule, ::Type{BalancedNetwork}) = as_network(m)
_narrow(m::StoredModule, ::Type{MulticonductorNetwork}) = as_dist_network(m)
_narrow(::StoredModule, value_type::Type) =
    error("PowerIO.parse: value_type must be StoredModule, BalancedNetwork, or " *
          "MulticonductorNetwork; got $(value_type)")
