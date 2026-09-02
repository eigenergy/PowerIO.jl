# `TimeSeries{T}`, `ScenarioSet{T}`, and `OperatingPoint{N}` over handles that keep
# their module alive. Entries are typed values borrowed from the collection; no
# entry access serializes or copies a network.

function _with_handle(f, x)
    h = getfield(x, :handle)
    return GC.@preserve h f(getfield(h, :lib), _ptr(h))
end

# --- TimeSeries ---------------------------------------------------------------

Base.length(s::TimeSeries) = _with_handle(s) do lib, p
    Int(ccall(_library_symbol(lib, :pio_time_series_len), Csize_t, (Ptr{Cvoid},), p))
end
Base.size(s::TimeSeries) = (length(s),)
Base.firstindex(::TimeSeries) = 1
Base.lastindex(s::TimeSeries) = length(s)
Base.eachindex(s::TimeSeries) = 1:length(s)
Base.eltype(::Type{TimeSeries{T}}) where {T} = T
Base.isempty(s::TimeSeries) = length(s) == 0

"""
    series[i]

The value at 1-based position `i` of a time series.
"""
function Base.getindex(s::TimeSeries{T}, i::Integer) where {T}
    1 <= i <= length(s) || throw(BoundsError(s, i))
    return _with_handle(s) do lib, p
        vptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_time_series_get), Ptr{Cvoid},
                  (Ptr{Cvoid}, Csize_t, Ref{Ptr{Cvoid}}), p, Csize_t(i - 1), err)
        end
        _wrap_value(lib, ValueHandle(vptr, lib), nothing)::T
    end
end

Base.iterate(s::TimeSeries, i::Int=1) = i > length(s) ? nothing : (s[i], i + 1)

Base.show(io::IO, s::TimeSeries{T}) where {T} = print(io, "TimeSeries{", T, "} with ", length(s), " values")

# --- ScenarioSet ---------------------------------------------------------------

Base.length(s::ScenarioSet) = _with_handle(s) do lib, p
    Int(ccall(_library_symbol(lib, :pio_scenario_set_len), Csize_t, (Ptr{Cvoid},), p))
end
Base.isempty(s::ScenarioSet) = length(s) == 0
Base.eltype(::Type{ScenarioSet{T}}) where {T} = Pair{String,T}

"""
    keys(scenarios)

The scenario identifiers, in table order.
"""
Base.keys(s::ScenarioSet) = _with_handle(s) do lib, p
    n = Int(ccall(_library_symbol(lib, :pio_scenario_set_len), Csize_t, (Ptr{Cvoid},), p))
    [_str(ccall(_library_symbol(lib, :pio_scenario_set_id_at), PioStringView,
                (Ptr{Cvoid}, Csize_t), p, Csize_t(k - 1))) for k in 1:n]
end

Base.haskey(s::ScenarioSet, id::AbstractString) = String(id) in keys(s)

function _scenario_at(s::ScenarioSet{T}, k::Int) where {T}
    return _with_handle(s) do lib, p
        id = _str(ccall(_library_symbol(lib, :pio_scenario_set_id_at), PioStringView,
                        (Ptr{Cvoid}, Csize_t), p, Csize_t(k - 1)))
        vptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_scenario_set_get_at), Ptr{Cvoid},
                  (Ptr{Cvoid}, Csize_t, Ref{Ptr{Cvoid}}), p, Csize_t(k - 1), err)
        end
        id => _wrap_value(lib, ValueHandle(vptr, lib), nothing)::T
    end
end

"""
    scenarios[id]

The value of the scenario named `id`. Throws `KeyError` for an unknown id.
"""
function Base.getindex(s::ScenarioSet{T}, id::AbstractString) where {T}
    haskey(s, id) || throw(KeyError(id))
    id = String(id)
    return _with_handle(s) do lib, p
        vptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_scenario_set_get), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), p, id, sizeof(id), err)
        end
        _wrap_value(lib, ValueHandle(vptr, lib), nothing)::T
    end
end

Base.get(s::ScenarioSet, id::AbstractString, default) = haskey(s, id) ? s[id] : default
Base.values(s::ScenarioSet) = [last(_scenario_at(s, k)) for k in 1:length(s)]
Base.pairs(s::ScenarioSet) = s
Base.iterate(s::ScenarioSet, k::Int=1) = k > length(s) ? nothing : (_scenario_at(s, k), k + 1)

Base.show(io::IO, s::ScenarioSet{T}) where {T} = print(io, "ScenarioSet{", T, "} with ", length(s), " scenarios")

# --- OperatingPoint -----------------------------------------------------------

function Base.getproperty(point::OperatingPoint{N}, name::Symbol) where {N}
    name === :network || return getfield(point, name)
    sym = N === BalancedNetwork ? :pio_operating_point_balanced_network :
          :pio_operating_point_multiconductor_network
    return _with_handle(point) do lib, p
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, sym), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), p, err)
        end
        _network_from(N, ptr, lib)
    end
end

Base.propertynames(::OperatingPoint, private::Bool=false) = private ? (:network, :handle) : (:network,)

_network_from(::Type{BalancedNetwork}, ptr, lib) = BalancedNetwork(BalancedNetworkHandle(ptr, lib), nothing)
_network_from(::Type{MulticonductorNetwork}, ptr, lib) =
    MulticonductorNetwork(MulticonductorNetworkHandle(ptr, lib), nothing)

Base.show(io::IO, ::OperatingPoint{N}) where {N} = print(io, "OperatingPoint{", N, "}")
