# Language APIs

The cross language naming table (Rust, Python, Julia, C ABI) lives in the
powerio repository:
[docs/languages.md](https://github.com/eigenergy/powerio/blob/main/docs/languages.md).

Julia-specific notes:

- Julia adds `PowerIO.parse(io; from=format)` because multiple dispatch is the natural
  way to express IO input.
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
| `read_module` / `write_module` | `pio_module_read_json` / `pio_module_write_json` | `StoredModule.from_json` / `.to_json` |
| `module_kind` | `pio_module_kind` | `StoredModule.kind` |
| `state_inventory` / `export_state` | `pio_module_state_inventory_json` / `pio_module_export_state` | `.state_inventory()` / `.export_state()` |
| `dc_data` | `pio_dc_data_build` | `BalancedNetwork.dc_data` |
| `PowerIO.susceptance` | `pio_dc_data_susceptance` | `data["susceptance"]` |
| `PowerIO.from_indices` / `PowerIO.to_indices` | `pio_dc_data_from_indices` / `..._to_indices` | `data["from_indices"]` / `data["to_indices"]` |
| `PowerIO.row_ids` / `PowerIO.bus_ids` | `pio_dc_data_row_ids` / `..._bus_ids` | `data["row_ids"]` / `data["bus_ids"]` |
| `PowerIO.omitted` | `pio_dc_data_omitted_ids` + `..._omitted_reasons` | `data["omitted_ids"]` + `data["omitted_reasons"]` |
