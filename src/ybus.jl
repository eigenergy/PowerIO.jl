# Bus admittance matrices assembled in Julia from the element tables, following
# MATPOWER's `makeYbus` as the powerio matrix crate implements it
# (`powerio-matrix/src/matrix/ybus.rs`). For each in-service branch from bus
# `i` to bus `j` with series impedance `z = r + jx`, terminal shunts `y_fr` and
# `y_to`, and complex tap `a = tap * exp(j * shift)`:
#
#     Y[i,i] += (1/z + y_fr) / |a|^2
#     Y[j,j] += 1/z + y_to
#     Y[i,j] += -(1/z) / conj(a)
#     Y[j,i] += -(1/z) / a
#
# plus the bus shunts `Y[i,i] += (g_s + j b_s) / base_mva`. B' and B'' are the
# same kernel with fixed switches, negated.

"""
    BusMappedMatrix{T}

A sparse matrix over the bus table with its index maps: `idx_to_bus[k]` is
the bus id of row and column `k`, `bus_to_idx[id]` the row of bus `id`, and
`matrix` the `SparseMatrixCSC{T,Int}`.
"""
struct BusMappedMatrix{T}
    idx_to_bus::Vector{Int}
    bus_to_idx::Dict{Int,Int}
    matrix::SparseArrays.SparseMatrixCSC{T,Int}
end

Base.size(m::BusMappedMatrix) = size(m.matrix)
Base.show(io::IO, m::BusMappedMatrix{T}) where {T} =
    print(io, "BusMappedMatrix{", T, "}(", size(m.matrix, 1), " buses, ", SparseArrays.nnz(m.matrix), " stored entries)")

# Impedances and taps below this magnitude cannot be divided by; the value is
# `MIN_DIVISIBLE_MAGNITUDE` in the powerio matrix crate.
const _MIN_DIVISIBLE_MAGNITUDE = 1.4916681462400413e-154

function _ybus(net::BalancedNetwork; zero_resistance::Bool, zero_charging::Bool, unity_taps::Bool,
               zero_shifts::Bool, skip_bus_shunts::Bool, skip_zero_impedance::Bool)
    buses = collect(net.buses)
    n = length(buses)
    idx_to_bus = [b.id for b in buses]
    bus_to_idx = Dict(id => k for (k, id) in enumerate(idx_to_bus))
    base = net.base_mva
    (isfinite(base) && base > 0) ||
        throw(ArgumentError("PowerIO: the network base_mva must be finite and positive, got $base"))

    I = Int[]
    J = Int[]
    V = ComplexF64[]
    add!(i, j, y) = (push!(I, i); push!(J, j); push!(V, y))
    for (k, br) in enumerate(net.branches)
        br.in_service || continue
        i = get(bus_to_idx, br.from_bus_id, nothing)
        j = get(bus_to_idx, br.to_bus_id, nothing)
        (i === nothing || j === nothing) &&
            throw(ArgumentError("PowerIO: branch $k connects an unknown bus ($(br.from_bus_id), $(br.to_bus_id))"))
        r = zero_resistance ? 0.0 : br.resistance_pu
        x = br.reactance_pu
        magnitude = hypot(r, x)
        if magnitude < _MIN_DIVISIBLE_MAGNITUDE
            skip_zero_impedance && continue
            throw(ArgumentError("PowerIO: branch $k ($(br.from_bus_id) to $(br.to_bus_id)) has zero impedance; " *
                                "pass skip_zero_impedance=true to drop it"))
        end
        isfinite(magnitude) || throw(ArgumentError("PowerIO: branch $k has a non-finite impedance"))
        y_series = inv(complex(r, x))
        y_fr = zero_charging ? zero(ComplexF64) : complex(br.from_conductance_pu, br.from_susceptance_pu)
        y_to = zero_charging ? zero(ComplexF64) : complex(br.to_conductance_pu, br.to_susceptance_pu)
        tap = unity_taps ? 1.0 : br.effective_tap_ratio
        (isfinite(tap) && abs(tap) >= _MIN_DIVISIBLE_MAGNITUDE) ||
            throw(ArgumentError("PowerIO: branch $k has a tap ratio of $tap that cannot be divided by"))
        shift = zero_shifts ? 0.0 : deg2rad(br.phase_shift_degrees)
        a = tap * cis(shift)
        y_ff = (y_series + y_fr) / (tap * tap)
        y_tt = y_series + y_to
        y_ft = -y_series / conj(a)
        y_tf = -y_series / a
        all(y -> isfinite(real(y)) && isfinite(imag(y)), (y_ff, y_ft, y_tf, y_tt)) ||
            throw(ArgumentError("PowerIO: branch $k produces a non-finite admittance"))
        if i == j
            add!(i, i, y_ff + y_tt + y_ft + y_tf)
        else
            add!(i, i, y_ff)
            add!(j, j, y_tt)
            add!(i, j, y_ft)
            add!(j, i, y_tf)
        end
    end
    if !skip_bus_shunts
        for s in net.shunts
            s.in_service || continue
            k = get(bus_to_idx, s.bus_id, nothing)
            k === nothing && throw(ArgumentError("PowerIO: shunt at unknown bus $(s.bus_id)"))
            add!(k, k, complex(s.conductance_mw, s.susceptance_mvar) / base)
        end
    end
    Y = SparseArrays.sparse(I, J, V, n, n)
    return idx_to_bus, bus_to_idx, Y
end

_scheme_zero_resistance(scheme::Symbol, matrix::Symbol) =
    scheme === :bx ? matrix === :bdoubleprime :
    scheme === :xb ? matrix === :bprime :
    throw(ArgumentError("PowerIO: scheme must be :bx or :xb, got $(repr(scheme))"))

"""
    calc_admittance_matrix(net; include_taps=true, include_shifts=true, skip_zero_impedance=false)

The complex bus admittance matrix `Y = G + jB` in per unit on the system base,
following MATPOWER's `makeYbus`: series admittances, terminal charging,
transformer taps and phase shifts, and in-service bus shunts. A zero impedance
branch is an error unless `skip_zero_impedance=true` drops it. Returns a
[`BusMappedMatrix`](@ref). The argument is a `BalancedNetwork`, a
`PioModule{BalancedNetwork}`, or a path to parse.
"""
function calc_admittance_matrix(net::BalancedNetwork; include_taps::Bool=true, include_shifts::Bool=true,
                                skip_zero_impedance::Bool=false)
    idx_to_bus, bus_to_idx, Y = _ybus(net; zero_resistance=false, zero_charging=false,
                                      unity_taps=!include_taps, zero_shifts=!include_shifts,
                                      skip_bus_shunts=false, skip_zero_impedance)
    return BusMappedMatrix(idx_to_bus, bus_to_idx, SparseArrays.dropzeros!(Y))
end

"""
    calc_bprime_matrix(net; scheme=:bx, skip_zero_impedance=false)

MATPOWER's fast decoupled `B'` matrix: the negated imaginary part of a bus
admittance matrix built with unity taps, no line charging, no bus shunts, and
phase shifts kept. `scheme=:xb` also drops series resistance. Returns a real
[`BusMappedMatrix`](@ref).
"""
function calc_bprime_matrix(net::BalancedNetwork; scheme::Symbol=:bx, skip_zero_impedance::Bool=false)
    idx_to_bus, bus_to_idx, Y = _ybus(net; zero_resistance=_scheme_zero_resistance(scheme, :bprime),
                                      zero_charging=true, unity_taps=true, zero_shifts=false,
                                      skip_bus_shunts=true, skip_zero_impedance)
    return BusMappedMatrix(idx_to_bus, bus_to_idx, SparseArrays.dropzeros!(-imag(Y)))
end

"""
    calc_bdoubleprime_matrix(net; scheme=:bx, skip_zero_impedance=false)

MATPOWER's fast decoupled `B''` matrix: the negated imaginary part of a bus
admittance matrix built with phase shifts cleared and taps, charging, and bus
shunts kept. `scheme=:bx` (the default) also drops series resistance. Returns
a real [`BusMappedMatrix`](@ref).
"""
function calc_bdoubleprime_matrix(net::BalancedNetwork; scheme::Symbol=:bx, skip_zero_impedance::Bool=false)
    idx_to_bus, bus_to_idx, Y = _ybus(net; zero_resistance=_scheme_zero_resistance(scheme, :bdoubleprime),
                                      zero_charging=false, unity_taps=false, zero_shifts=true,
                                      skip_bus_shunts=false, skip_zero_impedance)
    return BusMappedMatrix(idx_to_bus, bus_to_idx, SparseArrays.dropzeros!(-imag(Y)))
end

for f in (:calc_admittance_matrix, :calc_bprime_matrix, :calc_bdoubleprime_matrix)
    @eval begin
        $f(m::PioModule{BalancedNetwork}; kwargs...) = $f(m.value; kwargs...)
        function $f(path::AbstractString; format::Union{AbstractString,Nothing}=nothing, kwargs...)
            m = parse(path; format)
            m isa PioModule{BalancedNetwork} ||
                throw(ArgumentError("PowerIO.$($(string(f))): $path holds a $(typeof(m.value)), not a BalancedNetwork"))
            return $f(m.value; kwargs...)
        end
    end
end
