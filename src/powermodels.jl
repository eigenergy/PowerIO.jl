# PowerModels.jl bridge: network data dictionaries through the PowerModels JSON
# writer and reader, plus the reference dictionary helpers PowerModels models
# consume.

_json_plain(x) = x
_json_plain(x::JSON3.Array) = [_json_plain(v) for v in x]
_json_plain(x::JSON3.Object) = Dict{String,Any}(String(k) => _json_plain(getproperty(x, k)) for k in keys(x))

"""
    to_powermodels(m::PioModule{BalancedNetwork}) -> Dict{String,Any}
    to_powermodels(net::BalancedNetwork) -> Dict{String,Any}

The network as a PowerModels network data dictionary, written by the PowerIO
PowerModels JSON writer: per unit powers, radian angles, string keyed
component tables. A bare `BalancedNetwork` works when it came straight from a
module; a network reached through a collection or an instance has no module of
its own, so pass the module instead.
"""
to_powermodels(m::PioModule{BalancedNetwork}) = _json_plain(JSON3.read(emit(m, "powermodels-json").text))

function to_powermodels(net::BalancedNetwork)
    owner = getfield(net, :owner)
    owner === nothing && throw(ArgumentError(
        "PowerIO.to_powermodels: this network has no module of its own; pass the PioModule it came from"))
    return _json_plain(JSON3.read(emit(PioModule(owner, net), "powermodels-json").text))
end

"""
    from_powermodels(data) -> PioModule{BalancedNetwork}

Parse PowerModels network data, given as a dictionary, a `NamedTuple`, or a
JSON string, into a network module.
"""
from_powermodels(data) = from_powermodels(JSON3.write(data))
from_powermodels(data::AbstractString) =
    parse(Vector{UInt8}(codeunits(data)); name="powermodels.json", format="powermodels-json")

"""
    PowerIO.calc_branch_t(branch::Dict) -> (tr, ti)

Transformer tap components from tap ratio and phase shift angle:
`tr = tap * cos(shift)`, `ti = tap * sin(shift)`, as `PowerModels.calc_branch_t`.
"""
function calc_branch_t(branch::Dict{String,<:Any})
    tap_ratio = branch["tap"]
    angle_shift = branch["shift"]
    return tap_ratio * cos(angle_shift), tap_ratio * sin(angle_shift)
end

"""
    PowerIO.calc_branch_y(branch::Dict) -> (g, b)

Series conductance and susceptance from `br_r + j br_x`. A zero impedance
yields `(0.0, 0.0)`, the convention of `PowerModels.calc_branch_y`.
"""
function calc_branch_y(branch::Dict{String,<:Any})
    r = branch["br_r"]
    x = branch["br_x"]
    y = iszero(r) && iszero(x) ? zero(complex(float(r), float(x))) : inv(complex(r, x))
    return real(y), imag(y)
end

const POWER_MODELS_ANGLE_BOUND_PAD = 1.0472

"""
    repair_powermodels_angle_bounds!(network_data::Dict; default_pad=1.0472)

Clamp every branch angle difference bound in a PowerModels network data
dictionary to `[-default_pad, default_pad]` radians, the correction
`PowerModels.correct_voltage_angle_differences!` applies: a lower bound at or
below `-pi/2` becomes `-default_pad`, an upper bound at or above `pi/2` becomes
`default_pad`, and a zero width band opens to the full pad. Returns the
dictionary.
"""
function repair_powermodels_angle_bounds!(network_data::Dict{String,<:Any};
                                          default_pad=POWER_MODELS_ANGLE_BOUND_PAD)
    for (_, branch) in get(network_data, "branch", Dict{String,Any}())
        angmin = branch["angmin"]
        angmax = branch["angmax"]
        angmin <= -pi / 2 && (branch["angmin"] = -default_pad)
        angmax >= pi / 2 && (branch["angmax"] = default_pad)
        if angmin == 0.0 && angmax == 0.0
            branch["angmin"] = -default_pad
            branch["angmax"] = default_pad
        end
    end
    return network_data
end

function _pm_component_dict(network_data::Dict{String,<:Any}, name::String; copy_rows::Bool=false)
    raw = get(network_data, name, Dict{String,Any}())
    return Dict(Base.parse(Int, string(k)) => (copy_rows ? deepcopy(v) : v) for (k, v) in raw)
end

"""
    build_powermodels_ref(network_data::Dict) -> Dict{Symbol,Any}

The flat equivalent of `PowerModels.build_ref(data)[:it][:pm][:nw][0]`
restricted to:

- `:bus`, `:gen`, `:branch`, `:load`, `:shunt`: integer keyed component tables
  filtered to active elements on active buses (`bus_type != 4`, status fields
  nonzero, live endpoints);
- `:arcs_from`, `:arcs_to`, `:arcs`: `(branch_id, from_bus, to_bus)` tuples;
- `:bus_arcs`, `:bus_gens`, `:bus_loads`, `:bus_shunts`: per bus index lists;
- `:ref_buses`: buses with `bus_type == 3`;
- `:baseMVA`.

Storage, switches, DC lines, and areas are not carried. Branch angle bounds in
`ref[:branch]` are repaired with [`repair_powermodels_angle_bounds!`](@ref) on
copies; every other table shares its rows with `network_data`.
"""
function build_powermodels_ref(network_data::Dict{String,<:Any})
    ref = Dict{Symbol,Any}()

    ref[:baseMVA] = network_data["baseMVA"]
    ref[:bus] = _pm_component_dict(network_data, "bus")
    ref[:gen] = _pm_component_dict(network_data, "gen")
    ref[:branch] = _pm_component_dict(network_data, "branch"; copy_rows=true)
    ref[:load] = _pm_component_dict(network_data, "load")
    ref[:shunt] = _pm_component_dict(network_data, "shunt")

    ref[:bus] = Dict(k => v for (k, v) in ref[:bus] if get(v, "bus_type", 1) != 4)
    active_buses = keys(ref[:bus])

    ref[:load] = Dict(k => v for (k, v) in ref[:load]
                      if get(v, "status", 1) != 0 && v["load_bus"] in active_buses)
    ref[:gen] = Dict(k => v for (k, v) in ref[:gen]
                     if get(v, "gen_status", 1) != 0 && v["gen_bus"] in active_buses)
    ref[:shunt] = Dict(k => v for (k, v) in ref[:shunt]
                       if get(v, "status", 1) != 0 && v["shunt_bus"] in active_buses)
    ref[:branch] = Dict(k => v for (k, v) in ref[:branch]
                        if get(v, "br_status", 1) != 0 &&
                           v["f_bus"] in active_buses && v["t_bus"] in active_buses)

    repair_powermodels_angle_bounds!(Dict{String,Any}("branch" => ref[:branch]))

    ref[:arcs_from] = [(i, branch["f_bus"], branch["t_bus"]) for (i, branch) in ref[:branch]]
    ref[:arcs_to] = [(i, branch["t_bus"], branch["f_bus"]) for (i, branch) in ref[:branch]]
    ref[:arcs] = [ref[:arcs_from]; ref[:arcs_to]]

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
