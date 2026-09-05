# Security

Report vulnerabilities through GitHub's private vulnerability reporting on this
repository (Security tab → Report a vulnerability). Do not open a public issue
for anything exploitable.

Memory safety defects in the binding layer (the ccall sites, the Arrow C Data
Interface import, handle lifetimes) are in scope here; defects in the parsers
or the C ABI itself belong to
[eigenergy/powerio](https://github.com/eigenergy/powerio/security).

Only the latest release is supported.

## Library resolution

`PowerIO` loads `libpowerio_capi` from the first of: `set_library!`, the
`POWERIO_CAPI` environment variable, the Preferences.jl `library` override, a
sibling `powerio` checkout's build (only when this package is a git checkout),
the sha256 pinned `powerio_capi` artifact, and a plain `libpowerio_capi` on the
loader path. Every candidate passes the ABI handshake before use, but the
handshake runs the library. To pin the library on a shared machine, set
`POWERIO_CAPI` or the Preferences override to a path only you can write.
