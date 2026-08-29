# Language APIs

The cross language naming table (Rust, Python, Julia, C ABI) lives in the
powerio repository:
[docs/languages.md](https://github.com/eigenergy/powerio/blob/main/docs/languages.md).

Julia-specific notes:

- Julia adds `parse_bytes(io; format=...)` because multiple dispatch is the
  natural way to express IO input.
- Julia does not use `convert` / `convert!` for file format conversion. In
  Julia, `Base.convert` means type conversion and `!` marks mutation; PowerIO
  returns new values.

## The ABI v6 vocabulary

The stored module and DC data surfaces spell one vocabulary in every
language. The Julia names below are the same words the Rust `DcNetworkData`
fields, the Python `dc_data` dictionary keys, and the C `pio_dc_data_*`
accessors use, and the susceptance formula names (`series_susceptance`,
`tap_adjusted_reactance`, `reactance_only`) are shared verbatim.

| Julia | C | Python |
|---|---|---|
| `parse_file` / `write_json` | `pio_parse_file` / `pio_module_write_json` | `powerio.parse` / `PioModule.to_json` |
| `kind` | `pio_module_kind` | `PioModule.kind` |
| `state_inventory` / `select_state` | `pio_module_state_inventory_json` / `pio_module_export_state` | `.state_inventory()` / `.export_state()` |
| `dc_data` | `pio_dc_data_build` | `BalancedNetwork.dc_data` |
| `susceptance` | `pio_dc_data_susceptance` | `data["susceptance"]` |
| `from_indices` / `to_indices` | `pio_dc_data_from_indices` / `..._to_indices` | `data["from_indices"]` / `data["to_indices"]` |
| `row_ids` / `bus_ids` | `pio_dc_data_row_ids` / `..._bus_ids` | `data["row_ids"]` / `data["bus_ids"]` |
| `omitted` | `pio_dc_data_omitted_ids` + `..._omitted_reasons` | `data["omitted_ids"]` + `data["omitted_reasons"]` |
