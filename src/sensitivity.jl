# AC islands and DC sensitivity factors, computed by the powerio library: the
# island partition through `pio_balanced_network_islands` and the PTDF and LODF
# through `pio_calc_sensitivities`, the routine the Rust and Python APIs call.

"""
    Island

One AC island of a balanced network: buses joined by in-service branches,
closed switches, and the in-service windings of three winding transformers.

- `bus_ids`: the island's source bus ids, ascending;
- `bus_indices`: their 1-based positions in `net.buses`, in the same order;
- `reference_bus_ids` and `reference_bus_indices`: its reference buses;
- `generator_rows`: 1-based positions in `net.generators` of the in-service
  generators on its buses;
- `hvdc_rows`: 1-based positions in `net.hvdc` of the in-service HVDC lines
  that tie it to another island;
- `supplied`: whether an in-service generator can supply it.
"""
struct Island
    bus_ids::Vector{Int}
    bus_indices::Vector{Int}
    reference_bus_ids::Vector{Int}
    reference_bus_indices::Vector{Int}
    generator_rows::Vector{Int}
    hvdc_rows::Vector{Int}
    supplied::Bool
end

"""
    NetworkIslands

The result of [`network_islands`](@ref): `islands`, largest first with ties in
ascending order of their smallest bus id, and the buses typed isolated, which
belong to no island, as `isolated_bus_ids` and their 1-based positions
`isolated_bus_indices` in `net.buses`.
"""
struct NetworkIslands
    islands::Vector{Island}
    isolated_bus_ids::Vector{Int}
    isolated_bus_indices::Vector{Int}
end

Base.length(r::NetworkIslands) = length(r.islands)
Base.getindex(r::NetworkIslands, i::Integer) = r.islands[i]
Base.iterate(r::NetworkIslands, state...) = iterate(r.islands, state...)
Base.eltype(::Type{NetworkIslands}) = Island

"""
    network_islands(net) -> NetworkIslands

Partition a balanced network into AC islands with the powerio library's own
rule (`BalancedNetwork::calc_islands` in Rust). Two buses share an island when
a path of in-service branches, closed switches, and in-service three winding
transformer windings joins them. HVDC lines do not join islands. A bus typed
`"ISOLATED"` belongs to no island, and an element that touches one joins
nothing through it; such buses are listed in `isolated_bus_ids`. The argument
is a `BalancedNetwork` or a `PioModule{BalancedNetwork}`.

```julia
r = network_islands(net)
length(r)                    # number of islands
r[1].bus_ids                 # the largest island
r[1].reference_bus_ids       # its reference buses
r.isolated_bus_ids
```
"""
function network_islands(net)
    net = _network(net)
    return _with_network(net) do lib, p
        ptr = _checked(lib) do err
            @capi lib :pio_balanced_network_islands(p, err)
        end
        h = IslandsHandle(ptr, lib)
        result = @with_handles h begin
            q = _ptr(h)
            n = Int(@capi lib :pio_islands_count(q))
            islands = Island[]
            for i in 1:n
                v = _at(LibPowerIO.PioIslandView, Val(:pio_islands_at), lib, q, i - 1)
                push!(islands, Island(_sizes(v.bus_ids), _sizes(v.bus_indices) .+ 1,
                                      _sizes(v.reference_bus_ids), _sizes(v.reference_bus_indices) .+ 1,
                                      _sizes(v.generator_rows) .+ 1, _sizes(v.hvdc_rows) .+ 1,
                                      v.supplied))
            end
            NetworkIslands(islands, _sizes(@capi lib :pio_islands_isolated_bus_ids(q)),
                           _sizes(@capi lib :pio_islands_isolated_bus_indices(q)) .+ 1)
        end
        release!(h)
        result
    end
end

"""
    PtdfMatrix

A dense DC power transfer distribution factor matrix with its axes.
`matrix[l, k]` is the flow on branch `l` per unit injected at bus `k` and
withdrawn at the reference bus of its island.

- `idx_to_branch[l]`: the 1-based position in `net.branches` of row `l`
  (three winding transformer windings follow the branches);
- `branch_ids[l]`: the stable identity of row `l`, the branch uid when the
  source states one and `"branches:<row>"` otherwise;
- `idx_to_bus[k]` and `bus_to_idx[id]`: the source bus id of column `k` and
  its inverse;
- `reference_bus_ids` and `reference_bus_indices`: every reference bus, each
  grounded, and its column, which is zero;
- `solver_path`: the factorization the library used.
"""
struct PtdfMatrix
    matrix::Matrix{Float64}
    idx_to_branch::Vector{Int}
    branch_ids::Vector{String}
    idx_to_bus::Vector{Int}
    bus_to_idx::Dict{Int,Int}
    reference_bus_ids::Vector{Int}
    reference_bus_indices::Vector{Int}
    solver_path::String
end

"""
    LodfMatrix

A dense DC line outage distribution factor matrix with its branch axis.
`matrix[l, k]` is the share of branch `k`'s pre-outage flow that moves onto
branch `l` when `k` goes out; the diagonal is `-1`, and a branch whose outage
splits an island has a zero column. `idx_to_branch`, `branch_ids`,
`reference_bus_ids`, and `solver_path` are as in [`PtdfMatrix`](@ref).
"""
struct LodfMatrix
    matrix::Matrix{Float64}
    idx_to_branch::Vector{Int}
    branch_ids::Vector{String}
    reference_bus_ids::Vector{Int}
    solver_path::String
end

Base.size(m::PtdfMatrix) = size(m.matrix)
Base.size(m::LodfMatrix) = size(m.matrix)
Base.show(io::IO, m::PtdfMatrix) =
    print(io, "PtdfMatrix(", size(m.matrix, 1), " branches, ", size(m.matrix, 2), " buses, references ",
          m.reference_bus_ids, ")")
Base.show(io::IO, m::LodfMatrix) =
    print(io, "LodfMatrix(", size(m.matrix, 1), " branches)")

# A row major span of `rows * columns` doubles as a `Matrix`.
_row_major(values::Vector{Float64}, rows::Int, columns::Int) =
    permutedims(reshape(values, columns, rows))

function _sensitivities(f, net, formula::AbstractString, solver::Union{Symbol,AbstractString})
    net = _network(net)
    formula = String(formula)
    solver = String(solver)
    return _with_network(net) do lib, p
        ptr = _checked(lib) do err
            @capi lib :pio_calc_sensitivities(p, formula, sizeof(formula), solver, sizeof(solver), err)
        end
        h = SensitivitiesHandle(ptr, lib)
        result = @with_handles h begin
            q = _ptr(h)
            m = Int(@capi lib :pio_sensitivities_n_branches(q))
            n = Int(@capi lib :pio_sensitivities_n_buses(q))
            idx_to_bus = _sizes(@capi lib :pio_sensitivities_bus_ids(q))
            references = _sizes(@capi lib :pio_sensitivities_reference_bus_indices(q)) .+ 1
            axes = (; idx_to_branch = _sizes(@capi lib :pio_sensitivities_branch_rows(q)) .+ 1,
                      branch_ids = [_str(@capi lib :pio_sensitivities_branch_identity(q, Csize_t(k - 1))) for k in 1:m],
                      idx_to_bus, references, reference_bus_ids = idx_to_bus[references],
                      solver_path = _str(@capi lib :pio_sensitivities_solver_path(q)))
            f(lib, q, m, n, axes)
        end
        release!(h)
        result
    end
end

const _SENSITIVITY_DOC = """
`formula` selects the branch susceptance: `"series_susceptance"` (the
default), `"tap_adjusted_reactance"` (MATPOWER's `makeBdc`), or
`"reactance_only"`. `solver` is `:auto` (the default: a dense factorization on
small cases, a sparse one on large cases), `:dense`, or `:sparse`, as in the
Python `calc_ptdf`. The DC bus susceptance matrix is grounded at every
reference bus, one row and column each, so every connected component of the
in-service branches needs a reference bus; a component without one, such as a
bus typed `"ISOLATED"` that no in-service branch reaches, is a `PowerIOError`
with code `BUILD.INDEX.UNGROUNDED_COMPONENT`. The branch axis is the one
[`calc_dc_index_map`](@ref) names. The library computes the PTDF and the LODF
from one factorization and returns them dense. The argument is a
`BalancedNetwork` or a `PioModule{BalancedNetwork}`."""

"""
    calc_ptdf(net; formula="series_susceptance", solver=:auto) -> PtdfMatrix

The DC power transfer distribution factors, branches by buses, with every
reference bus column zero. $_SENSITIVITY_DOC

```julia
H = calc_ptdf(net)
H.matrix[1, H.bus_to_idx[2]]   # flow on the first branch per unit at bus 2
H.reference_bus_ids
```
"""
function calc_ptdf(net; formula::AbstractString="series_susceptance",
                   solver::Union{Symbol,AbstractString}=:auto)
    return _sensitivities(net, formula, solver) do lib, q, m, n, axes
        values = _f64s(@capi lib :pio_sensitivities_ptdf(q))
        PtdfMatrix(_row_major(values, m, n), axes.idx_to_branch, axes.branch_ids, axes.idx_to_bus,
                   Dict(id => k for (k, id) in enumerate(axes.idx_to_bus)), axes.reference_bus_ids,
                   axes.references, axes.solver_path)
    end
end

"""
    calc_lodf(net; formula="series_susceptance", solver=:auto) -> LodfMatrix

The DC line outage distribution factors, branches by branches. $_SENSITIVITY_DOC
"""
function calc_lodf(net; formula::AbstractString="series_susceptance",
                   solver::Union{Symbol,AbstractString}=:auto)
    return _sensitivities(net, formula, solver) do lib, q, m, _, axes
        values = _f64s(@capi lib :pio_sensitivities_lodf(q))
        LodfMatrix(_row_major(values, m, m), axes.idx_to_branch, axes.branch_ids,
                   axes.reference_bus_ids, axes.solver_path)
    end
end
