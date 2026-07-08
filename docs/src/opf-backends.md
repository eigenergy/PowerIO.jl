# OPF instance backends

This page records the intended shape of PowerIO's optimal power flow (OPF) instance
generators: the derived, solver-agnostic problem data a client reads to build a model.
It is a design note for the `DcOpfInstance` / `AcOpfInstance` / `ScopfInstance` family,
not a description of a shipped API. Today only the DC-OPF instance exists in the Rust
core, and [`ScopfInstance`](@ref) is a Julia-side projection built by
[`goc3_scopf_data`](@ref).

## Instances are projections, not formats

An OPF instance is the numeric problem data for one class of OPF, keyed by stable ids
and per-class orderings, with no model-specific variable stacking and no solver
assumptions baked in. A client reads an instance and builds its own model on top of it.
The Rust core already treats its DC-OPF data this way: `build_opf_instance`
(`powerio-matrix`) scatters generator cost, bounds, thermal limits, and nodal load into
an `OpfInstance` from the general indexed network, and the caller turns that into a
solvable program.

[`ScopfInstance`](@ref) is the same idea for the security-constrained problem: buses,
shunts, AC/DC branches, transformer control sets, producers, consumers, zonal reserves,
contingency survivor sets, energy windows, and price blocks, all keyed by `uid` and
per-class GOC3 ordering. GOC3 is the input format; the instance is what a client reads.
No format is anointed in the core.

## Current state

| Instance | Class | Where | Status |
|---|---|---|---|
| `OpfInstance` | DC-OPF | `powerio-matrix` (Rust), `matrix/opf.rs` | shipped |
| `ScopfInstance` | SCOPF | PowerIO.jl [`goc3_scopf_data`](@ref) | shipped as a Julia projection |
| `AcOpfInstance` | AC-OPF | none yet | planned |

The DC-OPF instance lives in `powerio-matrix` because it is built from the incidence and
generator maps that crate already owns. The AC and security-constrained instances are not
matrix objects: they carry structured device, reserve, and contingency data, so
`powerio-matrix` is the wrong home for the family as it grows.

## Recommended direction

Introduce a `powerio-opf` crate that owns the OPF instance generators and depends on
`powerio-matrix` for the incidence and sensitivity pieces the DC instance needs. The
crate holds three instance types built by the same kind of projection function:

- `DcOpfInstance`: the current `OpfInstance`, renamed. It is DC-specific already (its
  own module docstring says "Static DC-OPF instance data"), so the DC-qualified name is
  the accurate one once siblings exist.
- `ScopfInstance`: the canonical Rust backing for the type PowerIO.jl projects today. It
  is blocked on the IR being able to represent reserves, contingencies, and cross-period
  energy budgets (eigenergy/powerio#235); until then PowerIO.jl keeps building it from the
  parsed GOC3 case, and the binding is a body swap when the Rust type lands.
- `AcOpfInstance`: the AC analog, introduced alongside the rename.

`powerio-matrix` stays focused on linear algebra artifacts (PTDF, LODF, incidence,
sensitivity). Keeping `OpfInstance` there while adding AC and SCOPF siblings would
overload that crate's scope.

### Migration for v0.7.0

Move the type to `powerio-opf` and rename `OpfInstance` to `DcOpfInstance`. Keep

```rust
#[deprecated(note = "renamed to DcOpfInstance")]
pub type OpfInstance = DcOpfInstance;
```

re-exported from `powerio-matrix` for one release so existing callers do not break at the
rename, then drop it. The type is `#[non_exhaustive]`, so the field-level churn is
contained.

### Instance versus model, so a second consumer is not confused

The name to protect is the layer, not the acronym. PowerIO emits *instances*: solver-
agnostic input data. A consumer reads an instance and produces a *model* (or *program*)
and, after solving, a *solution*. These are different types at different layers and should
keep different names:

- PowerIO: `DcOpfInstance`, `AcOpfInstance`, `ScopfInstance` (input data).
- ExaModelsPower.jl (via PowerIO.jl): reads an instance / [`to_powerdata`](@ref) rows and
  builds an `ExaModel`.
- A second in-house consumer builds its own differentiable and conic OPF *programs* and
  *solutions* on top of `powerio::parse_str`; its `OpfProgram` / `DcOpfSolution` names sit
  above the instance layer, not beside it.

Because that second consumer today only uses PowerIO's parser and rolls its own DC
assembly, `powerio-opf` should be designed so it can adopt `DcOpfInstance` later without
inheriting any ExaModels or GPU assumption. If both a `DcOpfInstance` (PowerIO, the data)
and a `DcOpfSolution` (consumer, the result) appear in one file, the instance/solution
suffix split keeps them unambiguous, and the crate path (`powerio_opf::DcOpfInstance`)
disambiguates the rest. No consumer is blocked by the rename; the risk is only naming
hygiene, and the layer split handles it.

### Binding alignment

Keep the Rust and Julia names identical across the C ABI boundary so each binding is a
body swap when the Rust type is ready: Rust `DcOpfInstance` / `AcOpfInstance` /
`ScopfInstance` bind to the same names in PowerIO.jl. [`ScopfInstance`](@ref) is already
named for its eventual Rust backing; `DcOpfInstance` / `AcOpfInstance` follow when the
crate exists.
