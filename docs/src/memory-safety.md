# Memory Safety

PowerIO.jl owns Rust memory only through these Julia objects:

- `BalancedNetworkHandle`: owns a `PioBalancedNetwork *` and frees it with `pio_balanced_network_release`.
- `MulticonductorNetworkHandle`: owns a `PioMulticonductorNetwork *` and frees it with `pio_multiconductor_network_release`.
- `StoredModule` (internal, behind [`PioModule`](@ref)): owns a `PioModule *` behind `pio_module_retain`/`pio_module_release`.
- `DcData`: owns a `PioDcData *` behind `pio_dc_data_retain`/`pio_dc_data_release`.
- `ArrowBuffers`: owns Arrow C Data Interface array and schema release callbacks.

`BalancedNetwork`, `MulticonductorNetwork`, dense arrays, copied Arrow tables, and JSON values are Julia owned data. They do not borrow Rust memory.

## Audit Findings

P0, resolved: live handles crossed library overrides. `set_library!` (`src/capi.jl`) changes the global library path. Previously, a network parsed from one library still called `to_dense`, `to_arrow`, `to_format`, module conversion, or distribution access through a different library selected by `set_library!`. Finalizers already captured the right free function, but normal reads still used the current library. Handles now store the allocating library, symbol lookup is cached per library, and every call that borrows a handle uses the handle library.

P0, resolved: `ArrowTable.close` invalidated extracted columns. The unsafe sequence was `t = to_arrow(...; copy=false)`, `col = t.id`, `close(t)`, then `col[1]`. Previously, that read reached released Arrow buffers. `ArrowBuffers`'s `closed` field and its idempotent release guard, and `ArrowColumn`'s `getindex` check against it (all in `src/arrow.jl`), make a read after close throw a Julia error before touching the wrapped buffer.

P1, resolved: the Arrow decoder trusted success from `pio_balanced_network_to_arrow` before checking the returned C Data Interface layout. A mismatched or stale producer that returned success with null child pointers, null buffer pointer arrays, missing release callbacks, negative lengths, null column names, or child lengths shorter than the parent row count made Julia dereference invalid memory. The decoder now validates release callbacks, root array layout, and each child array's schema, offsets, null count, and buffer pointers before every unsafe load, in the release callback checks, the root array layout checks, and `_check_child_array` (all in `src/arrow.jl`).

P2, resolved: free function lookup threw after a C allocation and before finalizer registration when a required free symbol was missing. The network and module constructor paths — `BalancedNetworkHandle` (`src/capi.jl`), `MulticonductorNetworkHandle` (`src/dist.jl`), and `StoredModule` (`src/v6.jl`) — now resolve the matching free function before calling `new`, then register a finalizer immediately when wrapping the pointer.

No signature mismatch was found between the Julia `ccall` declarations and `powerio-capi/include/powerio.h` for the checked symbols.

## C ABI Inventory

Handshake and identity: `pio_abi_version`, `pio_version`, `pio_has_feature`, `pio_build_info`, `pio_schema_versions_json`, `pio_classify_str`, and `pio_string_release`.

Parse and module API: `pio_parse_file`, `pio_parse_str`, `pio_parse_bytes`, `pio_module_read_json`, `pio_module_write_json`, `pio_module_write_str`, `pio_module_write_file`, `pio_module_kind`, `pio_module_diagnostics`, `pio_module_inspect_json`, `pio_module_state_inventory_json`, `pio_module_export_state`, `pio_module_lowering_readiness_json`, `pio_module_lower_to_balanced`, `pio_module_balanced_network`, `pio_module_multiconductor_network`, and the `pio_module_retain`/`pio_module_release` lifecycle. Failures cross as `PioError` handles (`pio_error_code`, `pio_error_message`, `pio_error_release`), and findings as `PioDiagnostics` lists with per field accessors.

Balanced network API: `pio_balanced_network_from_json`, `pio_balanced_network_to_json`, `pio_balanced_network_normalize`, `pio_convert_file`, `pio_convert_str`, the count and table extractors (`pio_balanced_network_n_buses`, `..._n_branches`, `..._n_gens`, `..._base_mva`, `..._ref_bus_index`, `..._ref_bus_indices`, `..._n_islands`, `..._is_radial`, `..._bus_ids`, `..._branches`, `..._gens`, `..._bus_demand`, `..._bus_shunt`), and the `pio_balanced_network_retain`/`pio_balanced_network_release` lifecycle.

Arrow API: `pio_balanced_network_to_arrow` and `pio_arrow_catalog_json`, plus the Arrow array and schema release callbacks returned by the C Data Interface.

Distribution API: `pio_multiconductor_network_summary_json`, `pio_multiconductor_network_to_json`, `pio_multiconductor_network_to_graph_json`, and the `pio_multiconductor_network_retain`/`pio_multiconductor_network_release` lifecycle; parsing and conversion go through the one parse and convert family above. The noun graph symbol remains a 0.10 compatibility alias.

DC data API: `pio_dc_data_build`, the span accessors (`pio_dc_data_susceptance`, `..._from_indices`, `..._to_indices`, `..._row_ids`, `..._bus_ids`, `..._shift`, `..._omitted_ids`, `..._omitted_reasons`), and the `pio_dc_data_retain`/`pio_dc_data_release` lifecycle.

## Guarantees

Under normal Julia use, public functions do not expose raw Rust owned pointers. A parsed network or module has one Julia owner with one finalizer. Finalizers capture the free function from the library that allocated the pointer, so `set_library!` affects future parses and conversions, not existing handles.

All public handle reads preserve the Julia handle across the C call. Dense extraction allocates Julia arrays, passes their buffers to Rust, validates returned counts against capacity, and returns only Julia owned arrays.

C strings returned by Rust are copied with `unsafe_string` before `pio_string_release`. The string is freed exactly once on successful return paths. Error returns are null and have no owned string to free.

`to_arrow(...; copy=true)` returns Julia owned vectors. `to_arrow(...; copy=false)` returns `ArrowColumn` objects rooted by a shared `ArrowBuffers` owner. A column outlives its table until the table is closed. After `close(table)`, reads from existing columns throw a Julia error.

The Arrow decoder validates the C Data Interface struct layout before dereferencing child or buffer pointers. A malformed successful Arrow return throws a Julia error instead of reading from null or inconsistent pointers.

Concurrent reads through the same network handle use the C header's read only rules. Every handle is an independently owned reference over an immutable value; no public operation mutates a shared handle.

## Remaining Conditions

Do not bypass the public API with `getfield(col, :data)` on an `ArrowColumn`. That field is an internal `unsafe_wrap` vector and does not carry the closed check by itself. Use normal indexing or `collect(col)`.

Do not call `ccall` directly on a network, module, or DC data handle pointer. Raw pointer use is outside the public API.

Do not close an `ArrowTable` concurrently with reading one of its columns from another Julia thread and then depend on either operation winning. The implementation serializes the actual read and release, so it will either return a value from an open buffer or throw after close, but close is still a mutating operation.
