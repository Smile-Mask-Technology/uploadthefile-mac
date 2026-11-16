# Security

## Reporting a vulnerability

Report vulnerabilities in the app, the `uptf` command-line tool or the `UptfKit` library privately,
either:

- on GitHub: **Security ▸ Report a vulnerability** in this repository, or
- by email to **abuse@uploadthefile.com** (the contact in
  https://uploadthefile.com/.well-known/security.txt).

Please include steps to reproduce and the version (`uptf --version`, or Get Info on the app in
Finder). Do not open a public issue for a vulnerability.

We confirm receipt, keep you informed while we work on a fix, then publish the fix in a new release
with a security advisory in this repository. Reporters who want to be credited are credited.

Issues in the uploadthefile.com service itself (the website, the API, pages on `*.upload.tf`) go
to the same address. To report abuse or illegal content, use https://uploadthefile.com/report
instead (no account needed).

## Supported versions

Security fixes go into the latest release. Please update to it; older versions are not patched.

## How the app handles your data

What the app keeps on your Mac, and why it is not sandboxed, is described in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#how-it-works).
