# Distribution networks

OpenDSS, PMD JSON, and BMOPF sources parse into a
[`MulticonductorNetwork`](@ref): buses with named terminals, lines with per
length impedance matrices, transformers with windings, loads and generators
with per terminal powers.

```julia
feeder = parse("IEEE13Nodeckt.dss")     # PioModule{MulticonductorNetwork}
net = feeder.value

net.name
net.base_frequency                       # 60.0
net.source_format                        # "dss"

net.buses                                # Elements{MulticonductorBus}
net.line_codes                            # Elements{MulticonductorLineCode}
net.lines
net.switches
net.transformers
net.loads
net.generators
net.ibrs                                 # inverter based resources
net.control_profiles
net.shunts
net.capacitors
net.voltage_sources
net.untyped_objects                              # source objects kept without a typed slot
net.commands                             # retained source commands (solve, ...)
net.options                              # name => value pairs
```

```julia
lc = net.line_codes[1]
lc.resistance                            # conductor_count square, ohm per metre
lc.reactance
lc.susceptance_from + lc.susceptance_to  # siemens per metre

line = net.lines[1]
line.bus_from, line.terminals_from       # "650", ["1", "2", "3"]
line.line_code, line.length_m

load = net.loads[1]
load.terminals                           # phases and neutral
load.active_power_nominal_w              # one entry per phase
load.voltage_model                       # "constant_power", ...
```

Units are SI (volts, watts, vars, metres, ohms, siemens), and terminal maps
are vectors of terminal names in the order the source lists them.

## Writing

`emit` writes the same three formats. If you read a module from OpenDSS and
change nothing, writing it as `"dss"` gives you the original `.dss` files
back; PMD JSON and BMOPF are canonical output, with diagnostics for whatever
the target format cannot represent.

```julia
emit(feeder, "dss", "copy.dss")
emit(feeder, "pmd").text
emit(feeder, "bmopf").text
```

OpenDSS, PMD JSON, and BMOPF are grid exchange formats: other tools read and
write them, and they enter PowerIO through `parse` and leave through `emit`.
PowerIO IR, written by `serialize` and read by `deserialize`, is PowerIO's own
serialization of a module, diagnostics and history included, for handing a
module to another PowerIO consumer. It is not an exchange format, and no other
tool reads it.

## Calculations

[`to_mc_ac_pf_instance`](@ref) and [`to_mc_ac_opf_instance`](@ref) construct
multiconductor power flow and optimal power flow instances from a network
module. The multiconductor admittance matrix is not bound in this release.

```@docs
MulticonductorNetwork
MulticonductorBus
MulticonductorLineCode
MulticonductorLine
MulticonductorSwitch
MulticonductorTransformer
MulticonductorTransformerWinding
MulticonductorLoad
MulticonductorGenerator
InverterBasedResource
ControlProfile
VoltVarControl
VoltWattControl
MulticonductorShunt
MulticonductorCapacitor
VoltageSource
UntypedObject
SourceCommand
```
