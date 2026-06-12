# gridfm-datakit Parquet reader over the C ABI.
#
# `pio_read_gridfm` (powerio-capi built `--features gridfm`) reads a gridfm-datakit
# Parquet dataset back into a network handle — the inverse of the gridfm writer, the
# ML→classical return leg. The reader itself lives in powerio-matrix, so it ships only
# when the C ABI is built with the gridfm feature; `gridfm_available()` probes the symbol
# (the mirror of `arrow_available`). The read is lossy but power-flow-complete; what the
# schema couldn't round-trip comes back in `warnings`, the same `\n`-joined warn buffer
# `convert_file` uses.

"""
    read_gridfm(dir; scenario=0) -> (; network::Network, scenario::Int, warnings::Vector{String})

Read one `scenario` of a gridfm-datakit Parquet dataset back into a [`Network`](@ref) —
the inverse of the gridfm writer. `dir` resolves leniently: the `raw/` directory holding
the parquet files, a `<case>/` directory with a `raw/` child, or a parent with one
`*/raw/` child. `scenario` selects one snapshot from a batch (`0`, the base case, by
default).

The read is lossy but power-flow-complete: it recovers bus types, voltages and limits,
nodal load and shunt totals, generator dispatch and bounds, branch
`r/x/b/tap/shift/rate_a`/angle-limits, and `base_mva` — enough to write a runnable case —
but not original bus ids (synthesized `1..n`), per-element load/shunt granularity,
piecewise/cubic costs, or HVDC/storage. What it can't recover is listed in `warnings`.

The returned `network` carries a live Rust handle, so the `to_*` transforms work on it.
Needs powerio-capi built `--features gridfm`; see [`gridfm_available`](@ref). For every
scenario in a batch use [`read_gridfm_scenarios`](@ref).
"""
function read_gridfm(dir::AbstractString; scenario::Integer=0)
    _ensure_compatible()
    warn = zeros(UInt8, _WARNLEN)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall((:pio_read_gridfm, _lib()), Ptr{Cvoid},
              (Cstring, Int64, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              String(dir), Int64(scenario), warn, length(warn), err, length(err))
    catch e
        _feature_call_error("read_gridfm", "pio_read_gridfm", "gridfm", e)
    end
    ptr == C_NULL && error("PowerIO.read_gridfm: " * _cstr(err))
    h = NetworkHandle(ptr)
    net = Network(JSON3.read(_to_json(h)), h)
    return (; network = net, scenario = Int(scenario),
            warnings = _warn_lines(warn; capped=true))
end

"""
    read_gridfm_scenarios(dir) -> Vector

Read every scenario of a gridfm dataset, one [`read_gridfm`](@ref) result per scenario id
(ascending) over the shared topology — the read side of a scenario batch. Each scenario is
rebuilt independently, so two may differ in branch status, bus types, and reference bus.
See [`read_gridfm`](@ref) for the lenient directory resolution and the fidelity contract.
"""
function read_gridfm_scenarios(dir::AbstractString)
    _ensure_compatible()
    return [read_gridfm(dir; scenario = id) for id in _gridfm_scenario_ids(dir)]
end

# The dataset's distinct scenario ids (ascending), via `pio_gridfm_scenario_ids`: a
# zero-capacity probe returns the count, then a second call fills the buffer (the count /
# caller-buffer pattern the dense extractors use).
function _gridfm_scenario_ids(dir::AbstractString)
    err = zeros(UInt8, _ERRLEN)
    d = String(dir)
    count = try
        ccall((:pio_gridfm_scenario_ids, _lib()), Cptrdiff_t,
              (Cstring, Ptr{Int64}, Csize_t, Ptr{UInt8}, Csize_t),
              d, C_NULL, 0, err, length(err))
    catch e
        _feature_call_error("read_gridfm_scenarios", "pio_gridfm_scenario_ids", "gridfm", e)
    end
    count < 0 && error("PowerIO.read_gridfm_scenarios: " * _cstr(err))
    ids = Vector{Int64}(undef, count)
    if count > 0
        n = ccall((:pio_gridfm_scenario_ids, _lib()), Cptrdiff_t,
                  (Cstring, Ptr{Int64}, Csize_t, Ptr{UInt8}, Csize_t),
                  d, ids, length(ids), err, length(err))
        n < 0 && error("PowerIO.read_gridfm_scenarios: " * _cstr(err))
        # Unlike the dense extractors' immutable handle, both calls re-read the
        # filesystem, so the count genuinely can change between probe and fill —
        # and a short fill would leave heap garbage in the tail of `ids`.
        Int(n) == count || error("PowerIO.read_gridfm_scenarios: scenario count " *
                                 "changed between probe and fill ($n vs $count)")
    end
    return ids
end

"""
    gridfm_available() -> Bool

True if the resolved C library exports `pio_read_gridfm` (built `--features gridfm`).
"""
gridfm_available() = _exports_symbol(:pio_read_gridfm)
