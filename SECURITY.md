# Security

Report vulnerabilities through GitHub's private vulnerability reporting on this
repository (Security tab → Report a vulnerability). Do not open a public issue
for anything exploitable.

Memory safety defects in the binding layer (the ccall sites, the Arrow C Data
Interface import, handle lifetimes) are in scope here; defects in the parsers
or the C ABI itself belong to
[eigenergy/powerio](https://github.com/eigenergy/powerio/security).

Only the latest release is supported.
