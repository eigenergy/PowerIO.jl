# --- ecosystem adapter surface -----------------------------------------

_json_plain(x) = x
_json_plain(x::JSON3.Array) = [_json_plain(v) for v in x]
_json_plain(x::JSON3.Object) =
    Dict(String(k) => _json_plain(getproperty(x, k)) for k in keys(x))

_has(obj, key::Symbol) = key in keys(obj)
_get(obj, key::Symbol, default) = _has(obj, key) ? getproperty(obj, key) : default

"""
    to_powermodels(net::BalancedNetwork) -> Dict{String,Any}

Convert a parsed network to a PowerModels network data dictionary through the
PowerIO writer. This is the post-parse network data shape PowerModels.jl consumes.
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
from_powermodels(data) = parse_str(JSON3.write(data), "powermodels-json")
from_powermodels(data::AbstractString) = parse_str(data, "powermodels-json")
