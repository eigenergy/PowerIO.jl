# --- ecosystem adapter API ---------------------------------------------

_json_plain(x) = x
_json_plain(x::JSON3.Array) = [_json_plain(v) for v in x]
_json_plain(x::JSON3.Object) =
    Dict(String(k) => _json_plain(getproperty(x, k)) for k in keys(x))

_has(obj, key::Symbol) = key in keys(obj)
_get(obj, key::Symbol, default) = _has(obj, key) ? getproperty(obj, key) : default

"""
    to_powermodels(net::BalancedNetwork) -> Dict{String,Any}

Convert a parsed network to a PowerModels network data dictionary through the
PowerIO writer. This is the post-parse network data layout PowerModels.jl consumes.
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
from_powermodels(data) = from_powermodels(JSON3.write(data))
from_powermodels(data::AbstractString) =
    parse_bytes(codeunits(data); name="powermodels.json", format="powermodels-json").value

# --- PowerModels reference utilities -------------------------------------
#
# Helpers for the `Dict{String,Any}` network data returned by
# `to_powermodels`, matching the semantics of their PowerModels.jl namesakes
# so a formulation ports without PowerModels as a dependency. The helpers that
# copy PowerModels names remain unexported. The public wrappers
# below use PowerIO specific names, so `using PowerModels, PowerIO` does not add
# avoid ambiguities.

"""
    PowerIO.calc_branch_t(branch::Dict) -> (Real, Real)

Transformer tap components from tap ratio and phase shift angle: `(tr, ti)`
where `tr = tap*cos(shift)` and `ti = tap*sin(shift)`. Matches
`PowerModels.calc_branch_t`.
"""
function calc_branch_t(branch::Dict{String,<:Any})
    tap_ratio = branch["tap"]
    angle_shift = branch["shift"]
    return tap_ratio * cos(angle_shift), tap_ratio * sin(angle_shift)
end

"""
    PowerIO.calc_branch_y(branch::Dict) -> (Real, Real)

Branch conductance and susceptance `(g, b)` from the series impedance
`br_r + j*br_x`. A zero impedance yields `(0.0, 0.0)`, the scalar
pseudo-inverse convention of `PowerModels.calc_branch_y`.
"""
function calc_branch_y(branch::Dict{String,<:Any})
    r = branch["br_r"]
    x = branch["br_x"]
    # Scalar pinv without the LinearAlgebra import: inv, with 0 for the
    # singular case — the same guard as `_branch_coeffs` in powerdata.jl.
    y = iszero(r) && iszero(x) ? zero(complex(float(r), float(x))) : inv(complex(r, x))
    return real(y), imag(y)
end

function _correct_branch_angle_differences!(branch_table, default_pad)
    for (_, branch) in branch_table
        angmin = branch["angmin"]
        angmax = branch["angmax"]
        angmin <= -pi / 2 && (branch["angmin"] = -default_pad)
        angmax >= pi / 2 && (branch["angmax"] = default_pad)
        if angmin == 0.0 && angmax == 0.0
            branch["angmin"] = -default_pad
            branch["angmax"] = default_pad
        end
    end
    return branch_table
end

function _branch_key_from_source(branch_table, source_id)
    if source_id isa AbstractVector && length(source_id) >= 2 && string(source_id[1]) == "branch"
        row = source_id[2]
        haskey(branch_table, row) && return row
        row_int = try
            Int(row)
        catch
            nothing
        end
        row_int !== nothing && haskey(branch_table, row_int) && return row_int
        row_string = string(row)
        haskey(branch_table, row_string) && return row_string
        for (id, branch) in branch_table
            get(branch, "index", nothing) == row && return id
        end
    end
    return nothing
end

"""
    PowerIO.correct_voltage_angle_differences!(network_data::Dict; default_pad=1.0472)

Clamp branch angle difference bounds to `±default_pad` (≈ π/3 rad). Full
PowerModels network data routes through PowerIO's normalize pass when a usable
library is loaded; a bare branch table, or no library, keeps the PowerModels
helper behavior. Angles are radians, the convention of [`to_powermodels`](@ref)
output.
"""
function correct_voltage_angle_differences!(network_data::Dict{String,<:Any};
                                            default_pad=POWER_MODELS_ANGLE_BOUND_PAD)
    branch_table = get(network_data, "branch", Dict{String,Any}())
    isempty(branch_table) && return network_data
    # The normalize route needs a live handle, so it needs a usable library. The
    # ABI equality gate covers the symbol: `pio_balanced_network_normalize` is not feature gated,
    # so there is nothing further to probe for.
    if !haskey(network_data, "baseMVA") || !haskey(network_data, "bus") ||
       !library_available()
        _correct_branch_angle_differences!(branch_table, default_pad)
        return network_data
    end
    corrected = to_normalized(
        from_powermodels(network_data);
        clamp_angle_bounds=true,
        angle_bound_pad=default_pad,
    )
    _correct_branch_angle_differences!(branch_table, default_pad)
    corrected_pm = to_powermodels(corrected)
    corrected_rows = sort(collect(values(get(corrected_pm, "branch", Dict{String,Any}())));
                          by = br -> br["index"])
    for (fixed_pm, fixed) in zip(corrected_rows, branches(corrected))
        id = _branch_key_from_source(branch_table, get(fixed_pm, "source_id", nothing))
        id === nothing && continue
        branch = branch_table[id]
        branch["angmin"] = fixed["angmin"]
        branch["angmax"] = fixed["angmax"]
    end
    return network_data
end

"""
    repair_powermodels_angle_bounds!(network_data::Dict; default_pad=1.0472)

Repair PowerModels branch angle bounds in place. This is the public PowerIO
name for the compatibility helper `correct_voltage_angle_differences!`.
"""
repair_powermodels_angle_bounds!(network_data::Dict{String,<:Any}; kwargs...) =
    correct_voltage_angle_differences!(network_data; kwargs...)

# Integer-keyed copy of one component table. Only `:branch` needs its rows
# copied (build_ref corrects angle bounds on them); the other tables share
# their row dicts with `network_data`.
function _pm_component_dict(network_data::Dict{String,<:Any}, name::String;
                            copy_rows::Bool=false)
    raw = get(network_data, name, Dict{String,Any}())
    return Dict(Base.parse(Int, string(k)) => (copy_rows ? deepcopy(v) : v)
                for (k, v) in raw)
end

"""
    PowerIO.build_ref(network_data::Dict) -> Dict{Symbol,Any}

Build a network reference dict from PowerModels network data (the
[`to_powermodels`](@ref) output). The result is the flat equivalent of
`PowerModels.build_ref(data)[:it][:pm][:nw][0]` restricted to:

- `:bus`, `:gen`, `:branch`, `:load`, `:shunt` — integer-keyed component
  tables filtered to active elements on active buses (`bus_type != 4`,
  status fields ≠ 0, live endpoints)
- `:arcs_from`, `:arcs_to`, `:arcs` — `(branch_id, from_bus, to_bus)` tuples
- `:bus_arcs`, `:bus_gens`, `:bus_loads`, `:bus_shunts` — per-bus index lists
- `:ref_buses` — buses with `bus_type == 3`
- `:baseMVA`

Not carried, unlike PowerModels: `:buspairs`, `:storage`, `:switch`,
`:dcline`/`:arcs_dc`, and `:areas` — storage or dclines present in
`network_data` do not appear in the ref. Branch angle bounds are corrected
via [`PowerIO.correct_voltage_angle_differences!`](@ref) on the copies in
`ref[:branch]`; `network_data` itself is not modified. Rows of every table
except `:branch` are shared with `network_data`, not copied.
"""
function build_ref(network_data::Dict{String,<:Any})
    ref = Dict{Symbol,Any}()

    ref[:baseMVA] = network_data["baseMVA"]
    ref[:bus]    = _pm_component_dict(network_data, "bus")
    ref[:gen]    = _pm_component_dict(network_data, "gen")
    ref[:branch] = _pm_component_dict(network_data, "branch"; copy_rows=true)
    ref[:load]   = _pm_component_dict(network_data, "load")
    ref[:shunt]  = _pm_component_dict(network_data, "shunt")

    ref[:bus] = Dict(k => v for (k, v) in ref[:bus] if get(v, "bus_type", 1) != 4)
    active_buses = keys(ref[:bus])

    ref[:load]   = Dict(k => v for (k, v) in ref[:load]
                        if get(v, "status", 1) != 0 && v["load_bus"] in active_buses)
    ref[:gen]    = Dict(k => v for (k, v) in ref[:gen]
                        if get(v, "gen_status", 1) != 0 && v["gen_bus"] in active_buses)
    ref[:shunt]  = Dict(k => v for (k, v) in ref[:shunt]
                        if get(v, "status", 1) != 0 && v["shunt_bus"] in active_buses)
    ref[:branch] = Dict(k => v for (k, v) in ref[:branch]
                        if get(v, "br_status", 1) != 0 &&
                           v["f_bus"] in active_buses &&
                           v["t_bus"] in active_buses)

    ref_data = copy(network_data)
    ref_data["branch"] = ref[:branch]
    correct_voltage_angle_differences!(ref_data)

    ref[:arcs_from] = [(i, branch["f_bus"], branch["t_bus"]) for (i, branch) in ref[:branch]]
    ref[:arcs_to]   = [(i, branch["t_bus"], branch["f_bus"]) for (i, branch) in ref[:branch]]
    ref[:arcs]      = [ref[:arcs_from]; ref[:arcs_to]]

    ref[:bus_loads] = Dict(i => Int[] for (i, _) in ref[:bus])
    for (i, load) in ref[:load]
        push!(ref[:bus_loads][load["load_bus"]], i)
    end

    ref[:bus_shunts] = Dict(i => Int[] for (i, _) in ref[:bus])
    for (i, shunt) in ref[:shunt]
        push!(ref[:bus_shunts][shunt["shunt_bus"]], i)
    end

    ref[:bus_gens] = Dict(i => Int[] for (i, _) in ref[:bus])
    for (i, gen) in ref[:gen]
        push!(ref[:bus_gens][gen["gen_bus"]], i)
    end

    ref[:bus_arcs] = Dict(i => Tuple{Int,Int,Int}[] for (i, _) in ref[:bus])
    for (l, i, j) in ref[:arcs]
        push!(ref[:bus_arcs][i], (l, i, j))
    end

    ref[:ref_buses] = Dict{Int,Any}(i => bus for (i, bus) in ref[:bus] if bus["bus_type"] == 3)

    return ref
end


"""
    build_powermodels_ref(network_data::Dict) -> Dict{Symbol,Any}

Build the PowerModels compatible reference dictionary documented by
[`to_powermodels`](@ref). The shorter compatibility name `build_ref` remains
available as `PowerIO.build_ref` but is not exported.
"""
build_powermodels_ref(network_data::Dict{String,<:Any}) = build_ref(network_data)
