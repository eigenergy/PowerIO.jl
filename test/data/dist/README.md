# Distribution test fixtures

`switch.dss` is vendored verbatim from the powerio repository's micro OpenDSS
test cases (`tests/data/dist/micro/switch.dss`). It exercises the distribution
binding's parse / serialize / convert path (`parse_file(MulticonductorNetwork, …)`,
`to_format`, `convert_file(MulticonductorNetwork, …)`).

`generator.dss` is the minimal reproducer for BMOPFTools.jl issue #190. The
OpenDSS parser keeps `Generator.g1`: the same Julia handle writes it as a PMD
`generator`. The current Rust BMOPF writer emits fixed P/Q OpenDSS generation
without cost as a negative `load` instead, so the loss happens inside the
`powerio-dist` BMOPF writer, before Julia receives the JSON string.

Released under the Creative Commons Attribution 4.0 International license
(<https://creativecommons.org/licenses/by/4.0/>).

Attribution: "micro distribution test cases, eigenergy powerio contributors,
<https://github.com/eigenergy/powerio>".
