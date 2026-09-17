# Contingency analysis

PSS/E states a contingency study in three text files beside the case. PowerIO
reads each one into its own value type, binds a study to a network, and writes
every file back.

## Vocabulary

A **contingency set** is the content of a `.con` file: named cases, each a list
of outage actions such as opening a branch or removing a machine. A case may
also be stated as an *automatic specification*, a rule that names a group of
elements instead of listing them.

A **subsystem** is PSS/E's name for a bus selection stated in a `.sub` file
through bus, area, zone, owner, and kV range selectors. Automatic
specifications in a `.con` file and statements in a `.mon` file name
subsystems.

A **monitored set** is the content of a `.mon` file: the elements whose loading
and voltage a study reports.

## Reading the files

`parse` recognizes all three formats from the file name and content, so a
parsed module carries the typed value and the reader's notes:

```julia
using PowerIO

cases = parse("study.con")          # PioModule{ContingencySet}
groups = parse("groups.sub")        # PioModule{SubsystemSet}
monitored = parse("monitored.mon")  # PioModule{MonitoredSet}

length(cases.value)                 # how many cases
cases.value.cases[1]                # the first case name
groups.value.names                  # the subsystem names, in the file's order
monitored.value.statement_count     # how many statements the reader kept
cases.diagnostics                   # what the reader found
```

Each value writes itself back. `set.text` is the writer's canonical form, which
normalizes spacing and quoting; `emit(cases, "psse-con")` reproduces the bytes
the reader kept when the module still holds its source.

```julia
emit(cases, "psse-con", "copy.con")
```

Text in memory reads through the type's own constructor, which carries the
reader's notes on the value itself:

```julia
cases = ContingencySet(read("study.con", String))
groups = SubsystemSet(read("groups.sub", String))
monitored = MonitoredSet(read("monitored.mon", String))
cases.diagnostics
```

## Binding a set to a network

[`resolve_contingencies`](@ref) binds every action of every case to the
elements of one balanced network. It reports rather than refuses: an action
naming no element of the network is kept with its reason, its case counts as
unresolved, and the actions of that case that did bind stay listed.

```julia
net = parse("case.raw").value
resolution = resolve_contingencies(net, cases)

resolution.cases                    # 20
resolution.resolved                 # 17
resolution.unresolved               # 3
resolution.unrecognized_statements  # 1

case = resolution[1]
case.name                           # "BR_1_2_C1"
case.components                     # [ContingencyComponent("branch", "1-2", 1, true)]
case.unresolved                     # UnresolvedAction[]
```

A component names the table its `row` indexes, 1-based, and states the
element's own identity as `local_id`, or `nothing` when the network states
none for that row. An unresolved action carries the `.con` line the writer
produces for it and one of these reasons:

| Reason | What the action named |
|---|---|
| `:no_such_bus` | a bus the network does not state |
| `:no_such_branch` | a branch the network does not state |
| `:ambiguous_branch` | several branches, with no circuit to tell them apart |
| `:no_such_transformer_3w` | a three winding transformer the network does not state |
| `:ambiguous_transformer_3w` | several three winding transformers |
| `:no_such_machine` | a machine id the bus does not state |
| `:no_such_shunt` | a shunt the bus does not state |
| `:no_such_load` | a load the bus does not state |
| `:unrecognized` | a statement the reader kept as text |

A second method takes `.con` text directly, so a study reads and binds in one
step:

```julia
resolution = resolve_contingencies(net, read("study.con", String))
```

## Expanding automatic specifications

[`expand_contingencies`](@ref) turns every automatic specification into
explicit cases over one network and one subsystem set. A specification naming a
subsystem the subsystem set does not state stays in the returned set. The
returned notes are the contingency reader's, then the subsystem reader's, then
one note per specification that expanded into nothing.

```julia
expanded, notes = expand_contingencies(net, cases, groups)
expanded.cases        # ["EXPLICIT", "L_101_102_1", "L_102_103_1", ...]
write("expanded.con", expanded.text)
[d.code for d in notes]
```

The text method takes and returns text:

```julia
text, notes = expand_contingencies(net, read("study.con", String),
                                   read("groups.sub", String))
```

## Selecting the buses of a subsystem

[`select_subsystem_buses`](@ref) evaluates one named subsystem against a
network and gives its bus numbers in ascending order. The name is matched
without case and without surrounding whitespace, the way a `.con` or `.mon`
statement names a subsystem. A name the subsystem set does not state throws a
[`PowerIOError`](@ref) with code `"BIND.CAPI.INDEX_OUT_OF_RANGE"`.

```julia
select_subsystem_buses(net, groups, "A1")        # [101, 102, 103]
select_subsystem_buses(net, groups, " a1 ")      # the same subsystem
```

## Reference

```@docs
ContingencySet
SubsystemSet
MonitoredSet
ContingencyResolution
ContingencyCaseResult
ContingencyComponent
UnresolvedAction
resolve_contingencies
expand_contingencies
select_subsystem_buses
```
