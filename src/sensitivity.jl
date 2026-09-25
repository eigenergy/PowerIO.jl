"""
    PTDFResult

Deterministic DC power transfer distribution factors. `matrix[i, j]` gives the
change in branch-axis flow `i` for a +1 pu injection at `bus_axis[j]` balanced
by a -1 pu withdrawal at `reference_bus`. The branch and bus axes follow
`calc_dc_index_map`.
"""
struct PTDFResult{T<:AbstractMatrix}
    matrix::T
    bus_axis::Vector{Int}
    branch_axis::Vector{Int}
    reference_bus::Int
end

"""
    calc_ptdf(net; reference_bus=:auto, formula="series_susceptance",
              skip_zero_impedance=false) -> PTDFResult

Compute the deterministic DC power transfer distribution factor (PTDF) matrix
from the network existing DC operators.

`reference_bus=:auto` selects the first bus whose type is "REF", in table
order. An integer selects a bus id explicitly. The returned `bus_axis` contains
all buses except the reference bus, and each PTDF column represents a transfer
from that bus to the reference bus.

The calculation uses the same branch and bus axes as
[`calc_dc_index_map`](@ref), [`calc_bus_susceptance_matrix`](@ref), and
[`calc_branch_flow_matrix`](@ref). The reduced bus susceptance matrix must be
nonsingular; a singular reduced matrix is reported as a `PowerIOError` rather
than silently producing a pseudoinverse.

The result uses the package DC sign convention, so applying a transaction
vector `p` to `result.matrix` gives the corresponding branch-flow change in
the same orientation as [`calc_branch_flow_dc`](@ref).
"""
function calc_ptdf(net; reference_bus=:auto,
                   formula::AbstractString="series_susceptance",
                   skip_zero_impedance::Bool=false)
    net = _network(net)
    axes = calc_dc_index_map(net; formula=formula, skip_zero_impedance=skip_zero_impedance)
    bus_ids = collect(axes.idx_to_bus)

    ref = if reference_bus === :auto
        refs = reference_bus_ids(net)
        isempty(refs) && throw(PowerIOError("CALC.PTDF.NO_REFERENCE_BUS",
                                            "reference_bus=:auto requires at least one REF bus", Diagnostic[]))
        first(refs)
    elseif reference_bus isa Integer
        Int(reference_bus)
    else
        throw(ArgumentError("reference_bus must be :auto or a bus id"))
    end

    ref_idx = get(axes.bus_to_idx, ref, 0)
    ref_idx == 0 && throw(ArgumentError("reference bus $ref is not present in the network"))

    keep = [i for i in eachindex(bus_ids) if i != ref_idx]
    B = calc_bus_susceptance_matrix(net; formula=formula, skip_zero_impedance=skip_zero_impedance)
    Bf = calc_branch_flow_matrix(net; formula=formula, skip_zero_impedance=skip_zero_impedance)
    Bred = B[keep, keep]

    F = LinearAlgebra.lu(Bred; check=false)
    LinearAlgebra.issuccess(F) || throw(PowerIOError("CALC.PTDF.SINGULAR",
                                                       "reduced DC bus susceptance matrix is singular", Diagnostic[]))
    matrix = Matrix(transpose(F \ Matrix(transpose(Bf[:, keep]))))

    return PTDFResult(matrix, bus_ids[keep], collect(axes.idx_to_branch), ref)
end