# API reference

## The module

```@docs
PowerIO.PowerIO
```

## Modules and parsing

[`parse_file`](@ref), [`PioModule`](@ref), the diagnostic records, and the
module operations are documented on [Modules](modules.md).

## Networks and transforms

Keep the parsed module and call [`emit`](@ref) for a case format. Use
[`to_json`](@ref) for structured module or network JSON.

```@autodocs
Modules = [PowerIO]
Pages = ["network.jl"]
```

## Accessors

Module diagnostics use the `m.diagnostics` field.

```@autodocs
Modules = [PowerIO]
Pages = ["accessors.jl"]
```

## Graph projections

```@autodocs
Modules = [PowerIO]
Pages = ["graphs.jl"]
```

## Dense numeric extraction

```@autodocs
Modules = [PowerIO]
Pages = ["dense.jl"]
```

## Matrices

```@autodocs
Modules = [PowerIO]
Pages = ["matrix.jl"]
```

## Arrow export

```@autodocs
Modules = [PowerIO]
Pages = ["arrow.jl"]
```

## PowerModels.jl bridge

```@autodocs
Modules = [PowerIO]
Pages = ["powermodels.jl"]
```

## ExaModelsPower / PowerData bridge

```@autodocs
Modules = [PowerIO]
Pages = ["exa.jl"]
Private = false
```

## Distribution networks

The distribution path is [`parse_file`](@ref), an explicit
[`to_balanced`](@ref) when the model must change, and [`emit`](@ref).

```@autodocs
Modules = [PowerIO]
Pages = ["dist.jl"]
```

## Modules and typed values

[`parse_file`](@ref), [`parse_text`](@ref), [`PioModule`](@ref), the typed
records, and the direct DC calculations are documented on
[Modules](modules.md).

## GridFM

GridFM directories parse through [`parse_file`](@ref) and return a scenario
set module.

```@autodocs
Modules = [PowerIO]
Pages = ["gridfm.jl"]
```

## Feature probes

```@autodocs
Modules = [PowerIO]
Pages = ["features.jl"]
```

## Library resolution and ABI

```@autodocs
Modules = [PowerIO]
Pages = ["capi.jl"]
```
