# Calculation instances and solutions, and the `to_*_instance` constructions.

const _MULTICONDUCTOR_INSTANCES = Union{McAcPfInstance,McAcOpfInstance}
const _MULTICONDUCTOR_SOLUTIONS = Union{McAcPfSolution,McAcOpfSolution}

_network_type(::Type{<:_MULTICONDUCTOR_INSTANCES}) = MulticonductorNetwork
_network_type(::Type{<:CalculationInstance}) = BalancedNetwork
_network_type(::Type{<:_MULTICONDUCTOR_SOLUTIONS}) = MulticonductorNetwork
_network_type(::Type{<:CalculationSolution}) = BalancedNetwork

"""
    instance.network

The network a calculation instance is defined over.
"""
function Base.getproperty(instance::T, name::Symbol) where {T<:CalculationInstance}
    name === :network || return getfield(instance, name)
    N = _network_type(T)
    sym = N === BalancedNetwork ? :pio_calculation_instance_balanced_network :
          :pio_calculation_instance_multiconductor_network
    return _with_handle(instance) do lib, p
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, sym), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), p, err)
        end
        _network_from(N, ptr, lib)
    end
end

Base.propertynames(::CalculationInstance, private::Bool=false) = private ? (:network, :handle) : (:network,)

"""
    solution.instance
    solution.termination
    solution.objective

The instance a solution answers, the solver termination status (`"converged"`,
`"iteration_limit"`, `"infeasible"`, `"unbounded"`, `"failed"`, or
`"not_reported"`), and the reported objective value, or `nothing` when the
solution carries none. `SocwrOpfSolution` reports `objective_lower_bound`
instead of `objective`.
"""
function Base.getproperty(solution::T, name::Symbol) where {T<:CalculationSolution}
    if name === :instance
        return _with_handle(solution) do lib, p
            ptr = _checked(lib) do err
                ccall(_library_symbol(lib, :pio_calculation_solution_instance), Ptr{Cvoid},
                      (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), p, err)
            end
            handle = CalculationInstanceHandle(ptr, lib)
            type_name = GC.@preserve handle _str(ccall(_library_symbol(lib, :pio_calculation_instance_type_name),
                                                       PioStringView, (Ptr{Cvoid},), _ptr(handle)))
            I = _julia_type(type_name)
            I === nothing && error("PowerIO: unknown calculation instance type $type_name")
            I(handle)
        end
    elseif name === :termination
        return _with_handle(solution) do lib, p
            _str(ccall(_library_symbol(lib, :pio_calculation_solution_termination), PioStringView, (Ptr{Cvoid},), p))
        end
    elseif name === :objective
        T === SocwrOpfSolution && return nothing
        return _with_handle(solution) do lib, p
            out = Ref{Float64}(0.0)
            ok = ccall(_library_symbol(lib, :pio_calculation_solution_get_objective), Bool,
                       (Ptr{Cvoid}, Ref{Float64}), p, out)
            ok ? out[] : nothing
        end
    elseif name === :objective_lower_bound && T === SocwrOpfSolution
        return _with_handle(solution) do lib, p
            out = Ref{Float64}(0.0)
            ok = ccall(_library_symbol(lib, :pio_socwr_opf_solution_get_objective_lower_bound), Bool,
                       (Ptr{Cvoid}, Ref{Float64}), p, out)
            ok ? out[] : nothing
        end
    end
    return getfield(solution, name)
end

Base.propertynames(::CalculationSolution, private::Bool=false) =
    private ? (:instance, :termination, :objective, :handle) : (:instance, :termination, :objective)
Base.propertynames(::SocwrOpfSolution, private::Bool=false) =
    private ? (:instance, :termination, :objective_lower_bound, :handle) :
              (:instance, :termination, :objective_lower_bound)

"""
    solution[quantity]
    scuc_solution[quantity, t]

One named solution quantity as a `Vector{Float64}` in table order, such as
`solution["bus_voltage_magnitude"]`, `solution["bus_voltage_angle"]`,
`solution["generator_active_power"]`, or `solution["branch_from_active_flow"]`.
An `AcScucSolution` quantity takes a 1-based time position. Unknown quantities
throw [`PowerIOError`](@ref).
"""
function Base.getindex(solution::CalculationSolution, quantity::AbstractString)
    quantity = String(quantity)
    return _with_handle(solution) do lib, p
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_calculation_solution_get_values), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), p, quantity, sizeof(quantity), err)
        end
        _take_vector(lib, ptr)
    end
end

function Base.getindex(solution::AcScucSolution, quantity::AbstractString, t::Integer)
    quantity = String(quantity)
    return _with_handle(solution) do lib, p
        n = Int(ccall(_library_symbol(lib, :pio_ac_scuc_solution_time_count), Csize_t, (Ptr{Cvoid},), p))
        1 <= t <= n || throw(BoundsError(1:n, t))
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_ac_scuc_solution_get_values_at), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Csize_t, Ref{Ptr{Cvoid}}),
                  p, quantity, sizeof(quantity), Csize_t(t - 1), err)
        end
        _take_vector(lib, ptr)
    end
end

"""
    time_count(solution::AcScucSolution) -> Int

The number of time positions in an AC SCUC solution.
"""
time_count(solution::AcScucSolution) = _with_handle(solution) do lib, p
    Int(ccall(_library_symbol(lib, :pio_ac_scuc_solution_time_count), Csize_t, (Ptr{Cvoid},), p))
end

# Copy an owned `PioVector` and release it.
function _take_vector(lib::AbstractString, ptr::Ptr{Cvoid})
    h = VectorHandle(ptr, lib)
    values = GC.@preserve h _f64s(ccall(_library_symbol(lib, :pio_vector_values), PioF64View,
                                        (Ptr{Cvoid},), _ptr(h)))
    release!(h)
    return values
end

Base.show(io::IO, x::CalculationInstance) = print(io, nameof(typeof(x)), "()")
Base.show(io::IO, x::CalculationSolution) = print(io, nameof(typeof(x)), "(", x.termination, ")")

# --- constructions -------------------------------------------------------------

for (name, sym, doc) in (
        (:to_dc_pf_instance, :pio_module_to_dc_pf_instance, "a DC power flow instance"),
        (:to_ac_pf_instance, :pio_module_to_ac_pf_instance, "an AC power flow instance"),
        (:to_dc_opf_instance, :pio_module_to_dc_opf_instance, "a DC optimal power flow instance"),
        (:to_ac_opf_instance, :pio_module_to_ac_opf_instance, "an AC optimal power flow instance"),
        (:to_mc_ac_pf_instance, :pio_module_to_mc_ac_pf_instance, "a multiconductor AC power flow instance"),
        (:to_mc_ac_opf_instance, :pio_module_to_mc_ac_opf_instance, "a multiconductor AC optimal power flow instance"),
    )
    @eval begin
        Core.@doc $("""
            $name(m::PioModule) -> PioModule

        Construct $doc from a network module. The network is shared, not copied;
        the new module records the construction in its history.
        """) function $name(m::PioModule)
            lib = _lib_of(m)
            h = _handle(m)
            ptr = GC.@preserve h _checked(lib) do err
                ccall(_library_symbol(lib, $(QuoteNode(sym))), Ptr{Cvoid},
                      (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _ptr(h), err)
            end
            return _wrap_module(lib, ptr)
        end
    end
end
