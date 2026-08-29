# News

Release announcements. See [CHANGELOG.md](CHANGELOG.md) for the complete, itemized history.

## 0.10.0

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

Headline changes:

- `parse_file` and `parse_bytes` return a `PioModule{T}` instead of a bare network. `m.value` is the typed value, one of twenty kinds covering transmission and distribution networks, calculation instances and solutions, and time series and scenario sets. See [Migrating from 0.9](https://eigenergy.github.io/PowerIO.jl/migration-0.10/).
- `write_file(m, path)` with no `format` keyword writes the module's own source format, and for an unchanged module reproduces the source bytes exactly.
- The binding moves to C ABI 6, checked with `pio_abi_version` at first use. Distribution entry points are covered by the same handshake.
- Several 0.9 entry points are gone (the untyped package surface, the SCOPF projection, `OperatingPointSeries`, the distribution ABI probe) with a typed or module level replacement for each; see the migration guide for the full table.
