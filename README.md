# PowerIO.jl

Julia bindings for [PowerIO](https://github.com/eigenergy/caseio): a fast, lossless
reader/writer for power system case files. Parse MATPOWER, PSS/E, PowerWorld, and
PowerModels JSON, convert losslessly between them, and hand the data to the Julia
modeling and solver packages you already use.

PowerIO.jl is a thin wrapper over the PowerIO Rust core through its C ABI
(`powerio-capi`). It holds an opaque case handle, calls `pio_to_json` once, and
materializes an immutable `Network`; every accessor and every ecosystem bridge is
then pure Julia. The Rust core does the parsing and the byte-exact write, so a
case reads identically in Julia, Python, C/C++, and Rust.

> **Status: scaffold.** The package structure, C ABI layer, and milestone plan are
> here; it is not yet registered. The binary is wired through a local library path
> during development (below); milestone M1 replaces that with a registered
> `PowerIO_jll` built by Yggdrasil, so users get the binary with **no Rust
> toolchain** and a plain `Pkg.add("PowerIO")`.

## Develop (before `PowerIO_jll` exists)

Build the C ABI from the PowerIO Rust tree and point Julia at it:

```
# in the PowerIO repo:
cargo build -p powerio-capi --release        # → target/release/libpowerio_capi.{dylib,so}
```

```julia
using PowerIO
PowerIO.set_library!("/path/to/PowerIO/target/release/libpowerio_capi.dylib")
# or: ENV["POWERIO_CAPI"] = "...path..."  before `using PowerIO`

net = parse_case("case14.m")
PowerIO.n_buses(net), PowerIO.base_mva(net)
text, warnings = convert_case("case14.m", "psse")
```

## Why a JLL (not build-from-source)

`deps/build.jl` would run `cargo` on every user's machine and demand a Rust
toolchain — the deprecated path. Yggdrasil cross-compiles the Rust `cdylib`
**once**, publishes per-platform binaries as a registered `PowerIO_jll`, and
Julia's artifact system downloads the right one automatically. Users get the
"prebuilt, no toolchain" benefit the idiomatic, registry-blessed way. The
maintainer's local `cargo build` is only a dev override (above), never a user
step.

## Interop

Native, in-memory bridges to the Julia ecosystem, each a weak-dependency
extension so you only pay for what you load:

| Target | Direction | Mechanism | Milestone |
|---|---|---|---|
| PowerModels.jl | both | `to_powermodels` / `from_powermodels` (the post-parse, pre-`correct_network_data!` dict) | M3 |
| ExaPowerIO.jl / ExaModelsPower.jl | out | `to_powerdata` + a `parse_ac_power_data` NamedTuple feeding `opf_model` | M4 |
| PowerDiff.jl | both | `to_parsedcase` + a `:powerio` backend | M5 |
| MATPOWER / PSS/E / PowerModels JSON / EGRET | file | the Rust core's readers/writers | now |

## Milestones

- **M1 — C ABI + JLL keystone.** `pio_to_json`/`pio_from_json` (done in the Rust
  core), then a `build_tarballs.jl` on Yggdrasil → registered `PowerIO_jll`.
- **M2 — Core.** Typed immutable `Network` mirroring `powerio/src/network.rs`,
  the full accessor surface, `parse`/`convert`/`write`, CI, docs, register.
- **M3 — PowerModels parity.** `to_powermodels`/`from_powermodels` + a parity
  test reaching the same objective as `PowerModels.parse_file`.
- **M4 — ExaPowerIO/ExaModelsPower parity.** `to_powerdata` + `parse_ac_power_data`.
- **M5 — PowerDiff `:powerio` backend.**
- **M6 — Polish.** JLL-rebuild-from-local-Rust CI job, docs, v0.1.0.

## License

MIT.
