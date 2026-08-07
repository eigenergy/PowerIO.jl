# The reader's acceptance rule (powerio-pkg `supports_schema_version`):
# exact major.minor while the major is 0, major-only from 1.0.0.
# gen/update_artifacts.jl includes this file standalone; keep it free of
# package dependencies.
_same_schema_lineage(a::VersionNumber, b::VersionNumber) =
    a.major == b.major && (a.major != 0 || a.minor == b.minor)
_same_schema_lineage(a, b) =
    _same_schema_lineage(VersionNumber(String(a)), VersionNumber(String(b)))
