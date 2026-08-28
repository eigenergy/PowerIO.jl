# Memory Safety

PowerIO.jl owns Rust memory only through these Julia objects:

- `BalancedNetworkHandle`: owns a `PioNetwork *` and frees it with `pio_balanced_network_release`.
- `MulticonductorNetworkHandle`: owns a `PioDistNetwork *` and frees it with `pio_multiconductor_network_release`.
- `PackageHandle`: owns a `PioPackage *` and frees it with `pio_package_free`.
- `ArrowBuffers`: owns Arrow C Data Interface array and schema release callbacks.

`BalancedNetwork`, `MulticonductorNetwork`, dense arrays, copied Arrow tables, and JSON values are Julia owned data. They do not borrow Rust memory. `StoredModule` and `DcData` own C handles behind `retain`/`release` finalizers.

## Audit Findings

P0, resolved: live handles crossed library overrides. `set_library!` changes the global library path at `src/capi.jl:39`. Previously, a network parsed from one library still called `to_dense`, `to_arrow`, `to_format`, package conversion, or distribution access through a different library selected by `set_library!`. Finalizers already captured the right free function, but normal reads still used the current library. Handles now store the allocating library, symbol lookup is cached per library, and every call that borrows a handle uses the handle library.

P0, resolved: `ArrowTable.close` invalidated extracted columns. The unsafe sequence was `t = to_arrow(...; copy=false)`, `col = t.id`, `close(t)`, then `col[1]`. Previously, that read reached released Arrow buffers. `ArrowBuffers` now records a closed state and synchronizes reads with close; `ArrowColumn` reads after close throw a Julia error before touching the wrapped buffer. See `src/arrow.jl:145`, `src/arrow.jl:191`, and `src/arrow.jl:233`.

P1, resolved: the Arrow decoder trusted success from `pio_balanced_network_to_arrow` before checking the returned C Data Interface layout. A mismatched or stale producer that returned success with null child pointers, null buffer pointer arrays, missing release callbacks, negative lengths, null column names, or child lengths shorter than the parent row count made Julia dereference invalid memory. The decoder now validates release callbacks, root array layout, child schemas, child arrays, offsets, null counts, and buffer pointer arrays before each unsafe load. See `src/arrow.jl:131`, `src/arrow.jl:251`, `src/arrow.jl:266`, and `src/arrow.jl:278`.

P2, resolved: free function lookup threw after a C allocation and before finalizer registration when a required free symbol was missing. The parse and package constructor paths now resolve the matching free function before calling the C function that returns an owned pointer, then register a finalizer immediately when wrapping it. See `src/capi.jl:307`, `src/dist.jl:180`, and `src/package.jl:158`.

No signature mismatch was found between the Julia `ccall` declarations and `powerio-capi/include/powerio.h` for the checked symbols.

## C ABI Inventory

Core balanced API: `pio_abi_version`, `pio_version`, `pio_classify_str`, `pio_parse_file`, `pio_parse_str`, `pio_balanced_network_from_json`, `pio_warnings`, `pio_balanced_network_to_json`, `pio_balanced_network_release`, `pio_schema_versions_json`, and `pio_string_release`.

Balanced transforms, converters, and dense tables: `pio_balanced_network_normalize`, `pio_to_format`, `pio_convert_file`, `pio_convert_str`, `pio_write_dir`, `pio_balanced_network_n_buses`, `pio_balanced_network_n_branches`, `pio_balanced_network_n_gens`, `pio_balanced_network_base_mva`, `pio_balanced_network_ref_bus_index`, `pio_balanced_network_ref_bus_indices`, `pio_balanced_network_n_islands`, `pio_balanced_network_is_radial`, `pio_balanced_network_bus_ids`, `pio_balanced_network_branches`, `pio_balanced_network_gens`, `pio_balanced_network_bus_demand`, and `pio_balanced_network_bus_shunt`.

Arrow and matrix API: `pio_balanced_network_to_arrow`, `pio_matrix_available`, plus the Arrow array and schema release callbacks returned by the C Data Interface.

GridFM API: `pio_read_dir` and `pio_scenario_ids`.

Module API: `pio_module_read_json`, `pio_module_parse_file`, `pio_module_parse_str`, `pio_module_parse_bytes`, `pio_module_write_json`, `pio_module_as_network`, `pio_module_as_dist_network`, the inspection and selection entries, and the `pio_module_retain`/`pio_module_release` lifecycle.

Distribution API: `pio_dist_abi_version`, `pio_dist_capabilities_json`, `pio_dist_parse_file`, `pio_dist_parse_str`, `pio_multiconductor_network_release`, `pio_dist_warnings`, `pio_multiconductor_network_summary_json`, `pio_multiconductor_network_to_json`, `pio_multiconductor_network_graph_json`, `pio_dist_to_format`, `pio_dist_convert_file`, and `pio_dist_convert_str`.

## Guarantees

Under normal Julia use, public functions do not expose raw Rust owned pointers. A parsed network or module has one Julia owner with one finalizer. Finalizers capture the free function from the library that allocated the pointer, so `set_library!` affects future parses and conversions, not existing handles.

All public handle reads preserve the Julia handle across the C call. Dense extraction allocates Julia arrays, passes their buffers to Rust, validates returned counts against capacity, and returns only Julia owned arrays.

C strings returned by Rust are copied with `unsafe_string` before `pio_string_release`. The string is freed exactly once on successful return paths. Error returns are null and have no owned string to free.

`to_arrow(...; copy=true)` returns Julia owned vectors. `to_arrow(...; copy=false)` returns `ArrowColumn` objects rooted by a shared `ArrowBuffers` owner. A column outlives its table until the table is closed. After `close(table)`, reads from existing columns throw a Julia error.

The Arrow decoder validates the C Data Interface struct layout before dereferencing child or buffer pointers. A malformed successful Arrow return throws a Julia error instead of reading from null or inconsistent pointers.

Concurrent reads through the same network handle use the C header's read only rules. Public package validation does not mutate a shared package handle; it parses the immutable JSON package into a temporary handle, validates that handle, and materializes a new JSON package.

## Remaining Conditions

Do not bypass the public API with `getfield(col, :data)` on an `ArrowColumn`. That field is an internal `unsafe_wrap` vector and does not carry the closed check by itself. Use normal indexing or `collect(col)`.

Do not call `ccall` directly on `net.handle.ptr`, `pkg.handle.ptr`, or a distribution handle pointer. Raw pointer use is outside the public API.

Do not close an `ArrowTable` concurrently with reading one of its columns from another Julia thread and then depend on either operation winning. The implementation serializes the actual read and release, so it will either return a value from an open buffer or throw after close, but close is still a mutating operation.
