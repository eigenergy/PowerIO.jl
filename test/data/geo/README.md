# Geographic layer fixture

`case9.geo.json` is hand written for this repository: two bus points and one
branch route in geographic space, keyed by the `uid` spelling PowerIO writes.
It exercises `parse` returning `powerio.GeoLayer`, PowerIO IR carrying the
layer, and `emit(m, "geo-json")`.
