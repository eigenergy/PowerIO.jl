# News

Release announcements. See [CHANGELOG.md](CHANGELOG.md) for the complete, itemized history.

## 0.11.0

PowerIO.jl 0.11 binds PowerIO 0.11 over C ABI 7.

- `parse(source)` returns a `PioModule{T}`; `emit`, `serialize`, and
  `deserialize` write it out.
- Network tables are properties that return typed element structs:
  `net.buses[1].vm_pu`, `length(net.branches)`, `net.lines[1].line_code`.
- Time series and scenario sets index like Julia collections; calculation
  instances and solutions are typed values.
- Typed updates change a module in place through `apply_updates!`.
- See [Migrating from 0.10 to 0.11](https://eigenergy.github.io/PowerIO.jl/migration-0.11/)
  for every removed name and its replacement.

## 0.10.0

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

- `parse_file` and `parse_bytes` return a `PioModule{T}` instead of a bare network. `m.value` is the typed value, one of twenty kinds covering transmission and distribution networks, calculation instances and solutions, and time series and scenario sets. See the 0.10 migration guide in the [v0.10 documentation](https://eigenergy.github.io/PowerIO.jl/v0.10/migration-0.10/).
- `write_file(m, path)` with no `format` keyword writes the module's own source format, and for an unchanged module reproduces the source bytes exactly.
- The binding moves to C ABI 6, checked with `pio_abi_version` at first use. Distribution entry points are covered by the same handshake.
- Ordinary accessors are exported after `using PowerIO`, sparse matrix builders return `BusMappedMatrix`, and the PowerModels helpers use names that do not collide with PowerModels.jl.
- The migration guide lists removed names and their replacements.
