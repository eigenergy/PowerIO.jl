"""
    gridfm_available() -> Bool

True if the resolved C library was built with the gridfm feature.
"""
gridfm_available() = library_available() && has_feature("gridfm")
