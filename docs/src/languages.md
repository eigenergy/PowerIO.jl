# Language map

The Rust, Python, Julia, and C APIs use the same names for the same
operations. The complete table is in the powerio documentation
([Rust, Python, Julia, and C](https://powerio.dev/languages.html)); this page
covers what is specific to Julia.

| Meaning | Julia | Python | C ABI 7 |
|---|---|---|---|
| acquire a path | `parse("case.m")` | `parse(Path("case.m"))` | `pio_source_open` |
| acquire memory | `parse(io; name)`, `parse(bytes; name)` | pass a file or bytes-like object | `pio_source_from_memory` |
| parse | `parse(source; format)` | `parse(source, format=...)` | `pio_parse` |
| module value | `m.value` | `module.value` | `pio_module_value` |
| module diagnostics | `m.diagnostics` | `module.diagnostics` | `pio_module_diagnostics` |
| emit a format | `emit(m, format, destination)` | `emit(module, format, destination)` | `pio_emit` |
| serialize IR | `serialize(m, destination)` | `serialize(module, destination)` | `pio_module_serialize` |
| deserialize IR | `deserialize(source)` | `deserialize(source)` | `pio_module_deserialize` |
| apply updates | `apply_updates!(m, updates)` | `apply_updates(module, updates)` | `pio_apply_updates` |
| bus table | `net.buses` (`Elements{Bus}`) | `network.buses` (list of dicts) | `pio_balanced_network_bus_count`, `pio_balanced_network_bus_at` |
| time series entry | `series[1]` | `series[0]` | `pio_time_series_get(series, 0)` |
| scenario entry | `scenarios["7"]` | `scenarios["7"]` | `pio_scenario_set_get` |

## Julia specifics

`parse` extends `Base.parse` with methods for a path string, an `IO`, and a
byte vector. No Base method takes one positional argument, so existing code is
unaffected and the bare name works after `using PowerIO`.

There is no kind enum. You find out what a module holds by dispatching on its
type: `PioModule{BalancedNetwork}`, `PioModule{TimeSeries{BalancedNetwork}}`,
and so on.

Tables are properties returning `AbstractVector`s of immutable structs. Field
names follow the C header (`vm_pu`, `active_power_mw`), whereas Python uses
the MATPOWER short names (`vm`, `pg`).

Indices are 1-based: collection entries, sparse matrix positions, and the
`to_dense` bus rows. Bus ids and component ids are source identifiers and do
not change at the language boundary.

Errors are `PowerIOError` exceptions with the code, message, and diagnostics.
Python raises `PowerIOError` subclasses, and C writes one `PioError`.

Functions that mutate their argument end in `!`: `apply_updates!`,
`set_library!`, `repair_powermodels_angle_bounds!`.

Only Rust and C have a `Source` type, because those languages need an explicit
owner for acquired bytes. A Julia path, `IO`, or byte vector already says
where the bytes come from and who owns them.

The admittance matrices (`calc_admittance_matrix`, `calc_bprime_matrix`,
`calc_bdoubleprime_matrix`) are assembled in Julia, whereas Python reaches the
Rust implementation directly. The eight DC calculations come from the library
in all four languages.
