# Compact display of networks and elements. Every count is one C call, so
# showing a network never materializes its tables.

function Base.show(io::IO, net::BalancedNetwork)
    name = net.name
    print(io, "BalancedNetwork(")
    isempty(name) || print(io, repr(name), ", ")
    print(io, length(net.buses), " buses, ", length(net.branches), " branches, ",
          length(net.generators), " generators, ", length(net.loads), " loads)")
end

function Base.show(io::IO, net::MulticonductorNetwork)
    name = net.name
    counts = _mc_counts(net)
    print(io, "MulticonductorNetwork(")
    name === nothing || print(io, repr(name), ", ")
    print(io, Int(counts.buses), " buses, ", Int(counts.lines), " lines, ",
          Int(counts.transformers), " transformers, ", Int(counts.loads), " loads)")
end

Base.show(io::IO, b::Bus) = print(io, "Bus(", b.id, ", ", b.bus_type, ", vm_pu=", b.vm_pu,
                                  ", va_degrees=", b.va_degrees, ", base_kv=", b.base_kv, ")")
Base.show(io::IO, b::Branch) = print(io, "Branch(", b.from_bus_id, " => ", b.to_bus_id,
                                     ", r=", b.resistance_pu, ", x=", b.reactance_pu,
                                     b.in_service ? "" : ", out of service", ")")
Base.show(io::IO, g::Generator) = print(io, "Generator(bus ", g.bus_id, ", ", g.active_power_mw, " MW, ",
                                        g.reactive_power_mvar, " MVAr", g.in_service ? "" : ", out of service", ")")
Base.show(io::IO, l::Load) = print(io, "Load(bus ", l.bus_id, ", ", l.p_mw, " MW, ", l.q_mvar, " MVAr",
                                   l.in_service ? "" : ", out of service", ")")
Base.show(io::IO, s::Shunt) = print(io, "Shunt(bus ", s.bus_id, ", ", s.conductance_mw, " MW, ",
                                    s.susceptance_mvar, " MVAr", s.in_service ? "" : ", out of service", ")")
Base.show(io::IO, b::MulticonductorBus) = print(io, "MulticonductorBus(", repr(b.id), ", ",
                                                length(b.terminals), " terminals)")
Base.show(io::IO, l::MulticonductorLine) = print(io, "MulticonductorLine(", repr(l.name), ", ",
                                                 repr(l.bus_from), " => ", repr(l.bus_to), ", ",
                                                 l.length_m, " m)")
Base.show(io::IO, l::MulticonductorLoad) = print(io, "MulticonductorLoad(", repr(l.name), ", bus ",
                                                 repr(l.bus), ", ", sum(l.active_power_nominal_w) / 1e3, " kW)")
