"""
    features() -> NamedTuple

Return the optional C ABI surfaces available in the resolved library.

The fields are `arrow`, `matrix`, `gridfm`, `dist`, and `package`. Use this in
downstream packages instead of probing private symbols.
"""
features() = (;
    arrow = arrow_available(),
    matrix = matrix_available(),
    gridfm = gridfm_available(),
    dist = dist_available(),
    package = package_available(),
)
