# Normalized source rows over the C ABI (`pio_solver_index_json`, powerio
# v0.9).
#
# The normalize pass computes, for every row of its dense solver tables, the
# row of the source case that produced it. 0.9 made that the single map on
# purpose — "one map instead of two that could drift" — and it covers the
# star-lowered view the matrix builders read. This is the accessor for it.
#
# It sits beside `to_powerdata` rather than inside it: the source row map is a
# property of the pass, not of the ExaModels bridge, so it is reachable without
# going through the bridge and the bridge's row schema does not have to change.
# Reachable is all that means. The vectors are in the pass's row space, and
# `to_dense` reports the handle's parse-time tables, so they do not index a
# `to_dense` row and the two lengths differ on any case the pass drops from.

"""
    source_rows_available() -> Bool

True if the resolved C library exports `pio_solver_index_json` (powerio v0.9,
no cargo feature needed). A consumer that can work without source rows probes
this rather than resolving the symbol itself.
"""
source_rows_available() = _exports_symbol(:pio_solver_index_json)

# `nothing` rather than a sentinel: a synthetic row has no source row, and
# `0` or `-1` would be a number a caller can index with by accident. The C
# document spells it `null`; Julia spells it `nothing`.
const _SourceRows = Vector{Union{Nothing,Int}}

# The C document reports Rust row indices, which are 0-based. Every row number
# this package hands a caller is 1-based (`to_powerdata`'s `i`, the element
# table positions), so convert here, once, rather than leaving each consumer to
# discover the base.
function _source_rows(values)::_SourceRows
    out = _SourceRows(undef, length(values))
    for (i, v) in enumerate(values)
        out[i] = v === nothing ? nothing : Int(v) + 1
    end
    return out
end

"""
    source_rows(net) -> NamedTuple

The source row of each normalized solver-table row, per element table:
`bus`, `load`, `shunt`, `branch`, `switch`, `generator`, `storage`, `hvdc`.

Each field is a `Vector{Union{Nothing,Int}}` as long as that normalized table,
holding a **1-based** row of the source case, or `nothing` where the row has no
source — a synthetic three-winding star bus and the branches it lowers to.

This is the map the normalize pass computes for itself. Without it a consumer
that wants normalized tables plus source rows has to re-derive the pass's drop
rule from a second, unfiltered extraction — keep a generator if its `status` is
nonzero and its bus survived — which costs a full extra pass and is a guess at
the rule rather than the rule. The guess is wrong wherever normalization does
something it does not model; star lowering, which changes the branch count, is
the case, and a caller checking its own count against the filtered table then
fails on a case the library handled.

The ordering is the normalized one [`to_powerdata`](@ref) reports, so
`source_rows(net).generator[i]` is the source row of `to_powerdata(net).gen[i]`.
An out-of-service generator leaves a gap in the source rows instead of
renumbering the ones that survived.

[`to_dense`](@ref) is a *different* row space and these vectors do not index it.
Its tables come straight from the parse-time core the handle built, which still
holds the isolated buses and out-of-service branches the normalize pass drops,
so the two coincide only on a case that drops nothing. On
`test/data/norm_tiny.m`, `to_dense(net).bus_ids` has four entries where
`source_rows(net).bus` has three — and where the dropped rows come first the
misalignment is a wrong answer rather than a bounds error.

Needs a live network handle and a library that exports `pio_solver_index_json`;
[`source_rows_available`](@ref) reports the latter.

```julia
net = parse_file("case9.m")
pd = to_powerdata(net)
rows = source_rows(net)
rows.generator[1]   # the case row generator 1 came from, or `nothing`
```
"""
function source_rows(net::BalancedNetwork)
    # The handle's library, not `_lib()`: `set_library!` can swap the
    # configured build while this network is still alive, and its pointer is
    # the *parsing* build's allocation. Reading it through another build is a
    # type confusion the ABI handshake cannot see, and `_take_string` below is
    # a free that has to reach the allocator that made the string.
    h = _live_handle(net, "source_rows")
    lib = getfield(h, :lib)
    _ensure_compatible(lib)
    _require_export("source_rows", :pio_solver_index_json, "powerio v0.9", lib)
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_solver_index_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.source_rows: " * _cstr(err))
    doc = JSON3.read(_take_string(lib, s))
    index = doc.index
    return (;
        bus = _source_rows(index.bus_source_rows),
        load = _source_rows(index.load_source_rows),
        shunt = _source_rows(index.shunt_source_rows),
        branch = _source_rows(index.branch_source_rows),
        switch = _source_rows(index.switch_source_rows),
        generator = _source_rows(index.generator_source_rows),
        storage = _source_rows(index.storage_source_rows),
        hvdc = _source_rows(index.hvdc_source_rows),
    )
end
