# Language APIs

The cross language naming table (Rust, Python, Julia, C ABI) lives in the
powerio repository:
[docs/src/languages.md](https://github.com/eigenergy/powerio/blob/main/docs/src/languages.md).

Julia-specific notes:

- Julia uses `parse_file(io; name, format)` for streams as well as
  `parse_file(path; format)` for paths. Multiple dispatch distinguishes the
  physical input without adding another public verb.
- Julia does not use `convert` / `convert!` for file format conversion. In
  Julia, `Base.convert` means type conversion and `!` marks mutation; PowerIO
  returns new values.

## The shared vocabulary

The ordinary surface has the same shape in every language:

```text
parse_file -> PioModule { value, diagnostics } -> transform or matrix operation -> emit
```

| Concept | Julia | Python | C ABI |
|---|---|---|---|
| parse a path | `parse_file(path)` | `powerio.parse_file(path)` | `pio_parse_file` |
| read the value | `module.value` | `module.value` | `pio_module_kind`, then a typed accessor |
| diagnostics | `module.diagnostics` | `module.diagnostics` | `pio_module_diagnostics` |
| transform | `to_balanced(module)` | `module.to_balanced()` | `pio_module_to_balanced` |
| emit text | `emit(module, format)` | `module.emit(format)` | `pio_module_emit_string` |
| emit files | `emit(module, format, path)` | `module.emit(format, path)` | `pio_module_emit_file` |
| incidence | `calc_incidence_matrix(module)` | `net.calc_incidence_matrix()` | assemble from ABI 6 DC spans |
| bus susceptance | `calc_bus_susceptance_matrix(module)` | `net.calc_bus_susceptance_matrix()` | assemble from ABI 6 DC spans |
| branch susceptance | `calc_branch_susceptance_matrix(module)` | `net.calc_branch_susceptance_matrix()` | assemble from ABI 6 DC spans |
| phase shift injection | `calc_phase_shift_injection(module)` | `net.calc_phase_shift_injection()` | `pio_dc_data_shift_injection` |
| DC branch flow | `calc_branch_flow_dc(module, va)` | `net.calc_branch_flow_dc(va)` | `pio_dc_data_fill_branch_flow` |

Julia positions and collection indices are one based. Rust, Python, and C
dense positions are zero based. Source element identifiers keep their source
spelling in every language. The susceptance formula names
`series_susceptance`, `tap_adjusted_reactance`, and `reactance_only` are
shared verbatim.

The ABI 6 `DcData` spans remain available as a low level compatibility
surface in 0.10. They are documented in the [migration guide](migration-0.10.md),
not mixed into the ordinary Julia examples.
