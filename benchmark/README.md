# Local benchmark notes

Run from the PowerIO.jl repository root:

```julia
julia --project=/private/tmp/powerio-serde-bench benchmark/local_benchmarks.jl
```

The comparison below used the same benchmark script on the same machine. The
before run used `/private/tmp/PowerIO.jl-before` with
`/private/tmp/powerio-before/target/release/libpowerio_capi.dylib`. The after
run used this branch with the sibling `../powerio` release C ABI build.

| benchmark | before time | before allocs | before memory | after time | after allocs | after memory |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| balanced parse_file(case2869pegase) | 1.841 ms | 47 | 0.002 MiB | 1.840 ms | 47 | 0.002 MiB |
| balanced parse_file + net.data | 6.981 ms | 69 | 19.456 MiB | 7.112 ms | 69 | 19.456 MiB |
| balanced metadata + show | 1.739 ms | 92 | 0.004 MiB | 1.951 ms | 105 | 0.011 MiB |
| balanced calc_admittance_matrix(path) | 2.507 ms | 119 | 1.333 MiB | 2.530 ms | 119 | 1.333 MiB |
| balanced to_arrow(:bus) | 0.022 ms | 78 | 0.214 MiB | 0.022 ms | 78 | 0.214 MiB |
| balanced to_arrow(:branch) | 0.097 ms | 183 | 1.090 MiB | 0.097 ms | 183 | 1.090 MiB |
| JSON3.read balanced payload | 3.054 ms | 17 | 17.392 MiB | 3.115 ms | 17 | 17.392 MiB |
| Serde typed balanced payload | 14.320 ms | 643080 | 30.363 MiB | 14.541 ms | 643080 | 30.363 MiB |
| multiconductor parse_file(ieee13) | 0.209 ms | 7 | 0.001 MiB | 0.209 ms | 7 | 0.001 MiB |
| multiconductor parse_file + net.data | 0.305 ms | 26 | 0.241 MiB | 0.307 ms | 26 | 0.241 MiB |
| multiconductor metadata + show | 0.214 ms | 59 | 0.009 MiB | 0.212 ms | 59 | 0.009 MiB |
| PowerModelsDistribution parse baseline | 4.468 ms | 70341 | 3.978 MiB | 4.505 ms | 70341 | 3.978 MiB |

Serde was tested with concrete Julia structs for the balanced payload. It did
not beat JSON3 here, so PowerIO.jl keeps JSON3 for the rich cached payload and
uses Arrow for typed columnar access.
