# PSS/E contingency analysis files: the contingency set of a `.con` file, the
# subsystem set of a `.sub` file, the monitored set of a `.mon` file, and the
# binding of a contingency set to one balanced network.
#
# A set taken from a module borrows the module's data and holds the module
# alive in the C library, so it reads after the module handle is released and
# needs no owner field. A set read from text owns its own copy. Reader notes
# belong to whoever read the text: a set parsed here carries them, a set taken
# from a module carries none because the module holds them.

# --- ContingencySet ----------------------------------------------------------

"""
    ContingencySet(text; name="cases.con")

Read `.con` text into a contingency set. `name` is the source name diagnostics
report. Malformed text throws [`PowerIOError`](@ref).
"""
function ContingencySet(text::AbstractString; name::AbstractString="cases.con")
    lib = _checked_lib()
    source = _source_from_memory(lib, name, codeunits(text))
    ptr = @with_handles source _checked(lib) do err
        @capi lib :pio_contingency_set_parse(_ptr(source), err)
    end
    release!(source)
    handle = ContingencySetHandle(ptr, lib)
    notes = @with_handles handle @capi lib :pio_contingency_set_diagnostics(_ptr(handle))
    return ContingencySet(handle, _diagnostics(lib, notes))
end

function Base.getproperty(set::ContingencySet, name::Symbol)
    name === :text && return _with_handle(set) do lib, p
        _take_string(lib, _checked(lib) do err
            @capi lib :pio_contingency_set_to_con(p, err)
        end)
    end
    name === :cases && return _with_handle(set) do lib, p
        n = Int(@capi lib :pio_contingency_set_case_count(p))
        [_str(_checked(lib) do err
             @capi lib :pio_contingency_set_case_name(p, Csize_t(k - 1), err)
         end) for k in 1:n]
    end
    return getfield(set, name)
end

Base.propertynames(::ContingencySet, private::Bool=false) =
    private ? (:text, :cases, :diagnostics, :handle) : (:text, :cases, :diagnostics)

Base.length(set::ContingencySet) = _with_handle(set) do lib, p
    Int(@capi lib :pio_contingency_set_case_count(p))
end

function Base.show(io::IO, set::ContingencySet)
    n = length(set)
    print(io, "ContingencySet(", n, " case", n == 1 ? "" : "s", ")")
end

# --- SubsystemSet ------------------------------------------------------------

"""
    SubsystemSet(text; name="groups.sub")

Read `.sub` text into a subsystem set. `name` is the source name diagnostics
report. Malformed text throws [`PowerIOError`](@ref).
"""
function SubsystemSet(text::AbstractString; name::AbstractString="groups.sub")
    m = parse(codeunits(text); format="psse-sub", name=name)
    return SubsystemSet(getfield(m.value::SubsystemSet, :handle), m.diagnostics)
end

function Base.getproperty(set::SubsystemSet, name::Symbol)
    name === :text && return _with_handle(set) do lib, p
        _take_string(lib, _checked(lib) do err
            @capi lib :pio_subsystem_set_to_sub(p, err)
        end)
    end
    name === :names && return _with_handle(set) do lib, p
        n = Int(@capi lib :pio_subsystem_set_count(p))
        [_str(_checked(lib) do err
             @capi lib :pio_subsystem_set_name(p, Csize_t(k - 1), err)
         end) for k in 1:n]
    end
    return getfield(set, name)
end

Base.propertynames(::SubsystemSet, private::Bool=false) =
    private ? (:text, :names, :diagnostics, :handle) : (:text, :names, :diagnostics)

Base.length(set::SubsystemSet) = _with_handle(set) do lib, p
    Int(@capi lib :pio_subsystem_set_count(p))
end

function Base.show(io::IO, set::SubsystemSet)
    n = length(set)
    print(io, "SubsystemSet(", n, " subsystem", n == 1 ? "" : "s", ")")
end

# --- MonitoredSet ------------------------------------------------------------

"""
    MonitoredSet(text; name="monitored.mon")

Read `.mon` text into a monitored set. `name` is the source name diagnostics
report. Malformed text throws [`PowerIOError`](@ref).
"""
function MonitoredSet(text::AbstractString; name::AbstractString="monitored.mon")
    m = parse(codeunits(text); format="psse-mon", name=name)
    return MonitoredSet(getfield(m.value::MonitoredSet, :handle), m.diagnostics)
end

function Base.getproperty(set::MonitoredSet, name::Symbol)
    name === :text && return _with_handle(set) do lib, p
        _take_string(lib, _checked(lib) do err
            @capi lib :pio_monitored_set_to_mon(p, err)
        end)
    end
    name === :statement_count && return _with_handle(set) do lib, p
        Int(@capi lib :pio_monitored_set_statement_count(p))
    end
    return getfield(set, name)
end

Base.propertynames(::MonitoredSet, private::Bool=false) =
    private ? (:text, :statement_count, :diagnostics, :handle) :
              (:text, :statement_count, :diagnostics)

function Base.show(io::IO, set::MonitoredSet)
    n = set.statement_count
    print(io, "MonitoredSet(", n, " statement", n == 1 ? "" : "s", ")")
end

# --- resolution records ------------------------------------------------------

"""
    ContingencyComponent(component_type, local_id, row, in_service)

One network element a contingency case bound to. `component_type` names the
table `row` indexes, 1-based; `local_id` is the element's own identity, or
`nothing` when the network states none for that row; `in_service` is the
element's flag before the case is applied.
"""
struct ContingencyComponent
    component_type::String
    local_id::Union{String,Nothing}
    row::Int
    in_service::Bool
end

"""
    UnresolvedAction(action, reason)

One action of a case that bound to no element. `action` is the `.con` line the
writer produces for it, without its line ending. `reason` is one of
`:no_such_bus`, `:no_such_branch`, `:ambiguous_branch`,
`:ambiguous_transformer_3w`, `:no_such_machine`, `:no_such_shunt`,
`:no_such_load`, `:no_such_transformer_3w`, and `:unrecognized`.
"""
struct UnresolvedAction
    action::String
    reason::Symbol
end

"""
    ContingencyCaseResult

What binding one case to a network produced: its `name`, whether every action
bound (`resolved`), the `components` the actions bound to in action order, and
the `unresolved` actions that bound to nothing.
"""
struct ContingencyCaseResult
    name::String
    resolved::Bool
    components::Vector{ContingencyComponent}
    unresolved::Vector{UnresolvedAction}
end

"""
    ContingencyResolution

One contingency set bound to one balanced network, decoded in full.

- `cases`: how many cases the set states.
- `resolved`: how many cases had every action bind.
- `unresolved`: how many cases held at least one action that did not bind.
- `unrecognized_statements`: how many actions the reader kept as text, counted
  over every case.
- `case_results`: one [`ContingencyCaseResult`](@ref) per case, in the set's
  own order.
- `diagnostics`: the notes of the contingency set that was bound.

`length`, 1-based `getindex`, and iteration run over `case_results`.
"""
struct ContingencyResolution
    cases::Int
    resolved::Int
    unresolved::Int
    unrecognized_statements::Int
    case_results::Vector{ContingencyCaseResult}
    diagnostics::Vector{Diagnostic}
end

Base.length(r::ContingencyResolution) = length(r.case_results)
Base.getindex(r::ContingencyResolution, i::Integer) = r.case_results[i]
Base.firstindex(::ContingencyResolution) = 1
Base.lastindex(r::ContingencyResolution) = length(r.case_results)
Base.eltype(::Type{ContingencyResolution}) = ContingencyCaseResult
Base.iterate(r::ContingencyResolution, i::Int=1) =
    i > length(r.case_results) ? nothing : (r.case_results[i], i + 1)

Base.show(io::IO, r::ContingencyResolution) =
    print(io, "ContingencyResolution(", r.resolved, " of ", r.cases, " cases resolved)")

Base.show(io::IO, c::ContingencyCaseResult) =
    print(io, "ContingencyCaseResult(", repr(c.name), ", ",
          c.resolved ? "resolved" : "unresolved", ", ", length(c.components),
          " component", length(c.components) == 1 ? "" : "s", ")")

# One element a case bound to. The view's `row` is zero based and `local_id`
# states its absence through `len`, not through its pointer.
function _component(lib::AbstractString, p::Ptr{Cvoid}, case_index, component_index)
    v = _at(LibPowerIO.PioContingencyComponentView,
            Val(:pio_contingency_resolution_case_component), lib, p, case_index, component_index)
    return ContingencyComponent(_str(v.id.component_type),
                                _optional_str(v.id.local_id, v.id.local_id.len != 0),
                                Int(v.row) + 1, v.in_service)
end

# One action of a case that bound to nothing, with the reason the library names.
function _unresolved_action(lib::AbstractString, p::Ptr{Cvoid}, case_index, unresolved_index)
    action = _str(_checked(lib) do err
        @capi lib :pio_contingency_resolution_case_unresolved_action(p, case_index,
                                                                     unresolved_index, err)
    end)
    reason = _str(_checked(lib) do err
        @capi lib :pio_contingency_resolution_case_unresolved_reason(p, case_index,
                                                                     unresolved_index, err)
    end)
    return UnresolvedAction(action, Symbol(reason))
end

# Decode one resolution handle in full. `case_is_resolved` reads false both for
# a case holding an unbound action and for an index out of range, so the counts
# bound the loop and the unresolved list tells the two apart.
function _resolution(lib::AbstractString, h::ContingencyResolutionHandle,
                     diagnostics::Vector{Diagnostic})
    return @with_handles h begin
        p = _ptr(h)
        n = Int(@capi lib :pio_contingency_resolution_case_count(p))
        results = Vector{ContingencyCaseResult}(undef, n)
        for k in 1:n
            i = Csize_t(k - 1)
            name = _str(_checked(lib) do err
                @capi lib :pio_contingency_resolution_case_name(p, i, err)
            end)
            n_components = Int(@capi lib :pio_contingency_resolution_case_component_count(p, i))
            components = ContingencyComponent[_component(lib, p, i, Csize_t(j - 1))
                                              for j in 1:n_components]
            n_unresolved = Int(@capi lib :pio_contingency_resolution_case_unresolved_count(p, i))
            unresolved = UnresolvedAction[_unresolved_action(lib, p, i, Csize_t(j - 1))
                                          for j in 1:n_unresolved]
            resolved = @capi lib :pio_contingency_resolution_case_is_resolved(p, i)
            results[k] = ContingencyCaseResult(name, resolved, components, unresolved)
        end
        ContingencyResolution(n,
                              Int(@capi lib :pio_contingency_resolution_resolved_count(p)),
                              Int(@capi lib :pio_contingency_resolution_unresolved_count(p)),
                              Int(@capi lib :pio_contingency_resolution_unrecognized_statement_count(p)),
                              results, diagnostics)
    end
end

# --- operations --------------------------------------------------------------

"""
    resolve_contingencies(net::BalancedNetwork, cases::ContingencySet) -> ContingencyResolution
    resolve_contingencies(net::BalancedNetwork, text::AbstractString) -> ContingencyResolution

Bind every case of a contingency set to the elements of one balanced network.
Binding reports rather than refuses: an action naming no element of the network
is kept with its reason and its case counts as unresolved, while the actions of
that case that did bind stay listed. The text form reads `.con` text first, so
its result carries the reader's notes.
"""
function resolve_contingencies(net::BalancedNetwork, cases::ContingencySet)
    nh = getfield(net, :handle)
    sh = getfield(cases, :handle)
    lib = getfield(nh, :lib)
    ptr = @with_handles nh sh _checked(lib) do err
        @capi lib :pio_contingency_set_resolve(_ptr(sh), _ptr(nh), err)
    end
    handle = ContingencyResolutionHandle(ptr, lib)
    result = _resolution(lib, handle, cases.diagnostics)
    release!(handle)
    return result
end

resolve_contingencies(net::BalancedNetwork, text::AbstractString) =
    resolve_contingencies(net, ContingencySet(text))

"""
    expand_contingencies(net, cases::ContingencySet, subsystems::SubsystemSet) -> (ContingencySet, Vector{Diagnostic})
    expand_contingencies(net, con_text::AbstractString, sub_text::AbstractString) -> (String, Vector{Diagnostic})

Turn every automatic specification of a contingency set into explicit cases
over one balanced network and one subsystem set. A specification naming a
subsystem the subsystem set does not state stays in the returned set. The
returned notes are the contingency reader's, then the subsystem reader's, then
one note per specification that expanded into nothing. The text form returns
the expanded `.con` text.
"""
function expand_contingencies(net::BalancedNetwork, cases::ContingencySet,
                              subsystems::SubsystemSet)
    nh = getfield(net, :handle)
    ch = getfield(cases, :handle)
    sh = getfield(subsystems, :handle)
    lib = getfield(nh, :lib)
    notes = Ref{Ptr{LibPowerIO.PioDiagnostics}}(C_NULL)
    ptr = @with_handles nh ch sh notes _checked(lib) do err
        @capi lib :pio_contingency_set_expand(_ptr(ch), _ptr(nh), _ptr(sh), notes, err)
    end
    expansion = _diagnostics(lib, notes[])
    expanded = ContingencySet(ContingencySetHandle(ptr, lib), Diagnostic[])
    return expanded, vcat(cases.diagnostics, subsystems.diagnostics, expansion)
end

function expand_contingencies(net::BalancedNetwork, con_text::AbstractString,
                              sub_text::AbstractString)
    cases = ContingencySet(con_text)
    subsystems = SubsystemSet(sub_text)
    expanded, notes = expand_contingencies(net, cases, subsystems)
    return expanded.text, notes
end

"""
    select_subsystem_buses(net::BalancedNetwork, subsystems::SubsystemSet, name) -> Vector{Int}
    select_subsystem_buses(net::BalancedNetwork, sub_text::AbstractString, name) -> Vector{Int}

The bus numbers of one balanced network that the named subsystem selects, in
ascending order. The name is matched without case and without surrounding
whitespace, the way a `.con` or `.mon` statement names a subsystem. A name the
subsystem set does not state throws [`PowerIOError`](@ref) with code
`"BIND.CAPI.INDEX_OUT_OF_RANGE"`.
"""
function select_subsystem_buses(net::BalancedNetwork, subsystems::SubsystemSet,
                                name::AbstractString)
    nh = getfield(net, :handle)
    sh = getfield(subsystems, :handle)
    lib = getfield(nh, :lib)
    name = String(name)
    ptr = @with_handles nh sh name _checked(lib) do err
        @capi lib :pio_balanced_network_select_subsystem_buses(_ptr(nh), _ptr(sh), name,
                                                               sizeof(name), err)
    end
    return Int.(_take_vector(lib, ptr))
end

select_subsystem_buses(net::BalancedNetwork, sub_text::AbstractString, name::AbstractString) =
    select_subsystem_buses(net, SubsystemSet(sub_text), name)
