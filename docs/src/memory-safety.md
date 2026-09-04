# Memory safety

PowerIO.jl holds memory owned by the Rust library only through handle objects,
and copies every value it hands to Julia code.

## Handles

Each opaque C handle (`PioModule`, `PioBalancedNetwork`, `PioTimeSeries`,
`PioEmitResult`, `PioSparseMatrix`, and the rest) is wrapped by one mutable
Julia handle type with a finalizer that calls the family's release function.
The release function is resolved from the library that allocated the pointer
before the handle is constructed, so a `set_library!` switch after allocation
never releases a pointer through the wrong library. Every C call that takes a
handle runs inside `GC.@preserve` of that handle.

## Values that keep their module alive

A network, collection, instance, or solution borrowed from a module holds a
reference to the module's data inside the library. Releasing the module handle
does not invalidate the borrowed handle:

```julia
net = parse("case9.m").value   # the PioModule is unreachable after this line
GC.gc()
length(net.buses)              # still 9
```

Entries read from a `TimeSeries` or `ScenarioSet` and the network of an
instance work the same way.

## Copies

Element structs, diagnostics, module records, emitted file contents, sparse
matrices, and vectors are copied out of the borrowed C views before the call
returns; none of them points into library memory. A `Bus` read from
`net.buses[1]` stays valid after the network is released. The cost is one
allocation per element read; `collect(net.buses)` materializes a table once.

## Updates

`apply_updates!` changes a module in place. The library detaches the module's
data before a successful change, so a `BalancedNetwork` obtained before the
call keeps the old data and `m.value` is refreshed to the new one.

## Threads

Concurrent reads of one handle are allowed by the library. Releasing a handle
while another task uses it is a caller error; the Julia wrappers do not add a
lock, so share handles between tasks only for reads.
