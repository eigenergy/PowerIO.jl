# GridFM Parquet dataset reading: the dataset parses through the universal
# module surface as one scenario set over shared element identities
# (`parse_file(dir; format="gridfm")`), and each scenario selects out as an
# independent balanced module. Needs powerio-capi built `--features gridfm`.
"""
    read_gridfm(dir; scenario=0) -> (; network::BalancedNetwork, scenario::Int, warnings::Vector{String})

Read one `scenario` of a gridfm-datakit Parquet dataset back into a [`BalancedNetwork`](@ref) —
the inverse of the gridfm writer. `dir` resolves leniently: the `raw/` directory holding
the parquet files, a `<case>/` directory with a `raw/` child, or a parent with one
`*/raw/` child. `scenario` selects one snapshot from a batch (`0`, the base case, by
default).

The read is lossy but complete enough for power flow: it recovers bus types, voltages and limits,
nodal load and shunt totals, generator dispatch and bounds, branch
`r/x/b/tap/shift/rate_a`/angle-limits, and `base_mva` — enough to write a runnable case —
but not original bus ids (synthesized `1..n`), per-element load/shunt granularity,
piecewise/cubic costs, or HVDC/storage. What it can't recover is listed in `warnings`.

The returned `network` carries a live Rust handle, so the `to_*` transforms work on it.
Needs powerio-capi built `--features gridfm`; see [`gridfm_available`](@ref). For every
scenario in a batch use [`read_gridfm_scenarios`](@ref).
"""
function read_gridfm(dir::AbstractString; scenario::Integer=0)
    m = parse_file(String(dir); format="gridfm")
    m isa PioModule{ScenarioSet{BalancedNetwork}} || error(
        "PowerIO.read_gridfm: $dir parsed as a $(kind(m)) module")
    selected = select_state(m; scenario=string(scenario))
    selected isa PioModule{BalancedNetwork} || error(
        "PowerIO.read_gridfm: scenario $scenario selected a $(kind(selected)) module")
    # The reader's findings live on the scenario set; the exported scenario
    # carries its own. Both matter to the caller, reader first.
    return (; network = selected.value, scenario = Int(scenario),
            diagnostics = vcat(diagnostics(m), diagnostics(selected)))
end

"""
    read_gridfm_scenarios(dir) -> Vector

Read every scenario of a gridfm dataset, one [`read_gridfm`](@ref) result per scenario id
(ascending) over the shared topology — the read side of a scenario batch. Each scenario is
rebuilt independently, so two may differ in branch status, bus types, and reference bus.
See [`read_gridfm`](@ref) for the lenient directory resolution and fidelity notes.
"""
function read_gridfm_scenarios(dir::AbstractString)
    return [read_gridfm(dir; scenario=id) for id in _gridfm_scenario_ids(dir)]
end

# The dataset's distinct scenario ids (ascending), from the scenario set
# module's own inventory.
function _gridfm_scenario_ids(dir::AbstractString)
    m = parse_file(String(dir); format="gridfm")
    inventory = state_inventory(m)
    ids = [Base.parse(Int64, String(s.id)) for s in inventory.scenarios]
    return sort!(ids)
end

"""
    gridfm_available() -> Bool

True if the resolved C library was built with the gridfm feature.
"""
gridfm_available() = library_available() && has_feature("gridfm")
