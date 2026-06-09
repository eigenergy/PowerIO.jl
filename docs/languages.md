# Language APIs

PowerIO uses the same canonical API across Rust, Python, Julia, and the C ABI.
Julia keeps `parse_file(io, format)` because multiple dispatch is the natural
way to express IO input.

| Concept | Rust | Python | Julia | C ABI |
|---|---|---|---|---|
| Parse path | `parse_file(path)` | `parse_file(path, from_=None)` | `parse_file(path; from=nothing)` | `pio_parse_file` |
| Parse text | `parse_str(text, format)` | `parse_str(text, format)` | `parse_str(text, format)` | `pio_parse_str` |
| Parse IO | n/a | file object later | `parse_file(io, format)` | n/a |
| JSON to Network | `Network::from_json` | `from_json` | `from_json` | `pio_from_json` |
| File conversion | `convert_file(path, to, from)` | `convert_file(path, to, from_=None)` | `convert_file(path, to; from=nothing)` | `pio_convert_file` |
| Parsed conversion | `net.to_format(to)` | `net.to_format(to)` | `to_format(net, to)` | `pio_to_format` |
| MATPOWER text | `net.to_matpower()` | `net.to_matpower()` | `to_matpower(net)` | `pio_to_matpower` |
| JSON text | `net.to_json()` | `net.to_json()` | `to_json(net)` | `pio_to_json` |
| Normalized copy | `net.to_normalized()` | `net.to_normalized()` | `to_normalized(net)` | `pio_to_normalized` |
| Dense tables | typed table API | `to_dense` | `to_dense` | `pio_*` extractors |
| Arrow handoff | internal/C ABI | later | `to_arrow` | `pio_export_arrow` |

Julia does not use `convert` / `convert!` for file format conversion. In Julia,
`Base.convert` means type conversion and `!` marks mutation; PowerIO returns new
values.
