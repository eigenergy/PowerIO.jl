# Utilities for working with PowerModels-style network dictionaries, i.e. the
# `Dict{String,Any}` returned by `to_powermodels`.

import LinearAlgebra

"""
    calc_branch_t(branch::Dict) -> (Real, Real)

Calculate transformer tap components from tap ratio and phase shift angle.
Returns `(tr, ti)` where `tr = tap*cos(shift)` and `ti = tap*sin(shift)`.
"""
function calc_branch_t(branch::Dict{String,<:Any})
    tap_ratio = branch["tap"]
    angle_shift = branch["shift"]
    return tap_ratio * cos(angle_shift), tap_ratio * sin(angle_shift)
end

"""
    calc_branch_y(branch::Dict) -> (Real, Real)

Calculate branch conductance and susceptance from series impedance.
Returns `(g, b)` derived from `br_r + j*br_x` via pseudo-inverse.
"""
function calc_branch_y(branch::Dict{String,<:Any})
    y = LinearAlgebra.pinv(branch["br_r"] + im * branch["br_x"])
    return real(y), imag(y)
end

"""
    correct_voltage_angle_differences!(network_data::Dict; default_pad=1.0472)

Clamp branch angle difference bounds to `±default_pad` (≈ π/3 rad) when the
stored bounds are outside `±π/2` or are both zero. Matches the legacy MATPOWER
data correction applied by PowerModels.
"""
function correct_voltage_angle_differences!(network_data::Dict{String,<:Any};
                                            default_pad=1.0472)
    for (_, branch) in get(network_data, "branch", Dict{String,Any}())
        angmin = branch["angmin"]
        angmax = branch["angmax"]

        if angmin <= -pi / 2
            branch["angmin"] = -default_pad
        end
        if angmax >= pi / 2
            branch["angmax"] = default_pad
        end
        if angmin == 0.0 && angmax == 0.0
            branch["angmin"] = -default_pad
            branch["angmax"] = default_pad
        end
    end
    return network_data
end

function _pm_component_dict(network_data::Dict{String,<:Any}, name::String)
    raw = get(network_data, name, Dict{String,Any}())
    return Dict(parse(Int, string(k)) => deepcopy(v) for (k, v) in raw)
end

"""
    build_ref(network_data::Dict) -> Dict

Build a network reference dictionary from a PowerModels-style `network_data`
dict (e.g. from `to_powermodels`). The result contains integer-keyed component
tables (`:bus`, `:gen`, `:branch`, `:load`, `:shunt`) filtered to active
elements, plus pre-computed arc and adjacency lists:

- `:arcs_from`, `:arcs_to`, `:arcs` — `(line_id, from_bus, to_bus)` tuples
- `:bus_arcs`, `:bus_gens`, `:bus_loads`, `:bus_shunts` — per-bus index lists
- `:ref_buses` — buses with `bus_type == 3`
- `:baseMVA`

Angle difference bounds are corrected in-place on the returned `:branch` dict
via `correct_voltage_angle_differences!`.
"""
function build_ref(network_data::Dict{String,<:Any})
    ref = Dict{Symbol,Any}()

    ref[:baseMVA] = network_data["baseMVA"]
    ref[:bus]    = _pm_component_dict(network_data, "bus")
    ref[:gen]    = _pm_component_dict(network_data, "gen")
    ref[:branch] = _pm_component_dict(network_data, "branch")
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

    correct_voltage_angle_differences!(Dict("branch" => ref[:branch]))

    ref[:arcs_from] = [(i, branch["f_bus"], branch["t_bus"]) for (i, branch) in ref[:branch]]
    ref[:arcs_to]   = [(i, branch["t_bus"], branch["f_bus"]) for (i, branch) in ref[:branch]]
    ref[:arcs]      = [ref[:arcs_from]; ref[:arcs_to]]

    ref[:bus_loads]  = Dict(i => Int[] for (i, _) in ref[:bus])
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
