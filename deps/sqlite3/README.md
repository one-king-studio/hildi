# Vendored SQLite

This directory holds a pinned copy of the SQLite amalgamation used by
`hildegard.helper.store`. The project builds it into a shared library so the
helper carries a known SQLite version instead of relying on the host's.

- **Version:** 3.53.4 (amalgamation `3530400`)
- **Source:** https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
- **SHA3-256:** `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`

The amalgamation sources (`sqlite3.c`, `sqlite3.h`, `sqlite3ext.h`) are
**gitignored** and fetched on demand:

```sh
scripts/fetch-sqlite.sh
```

The script verifies the published SHA3-256 before extracting. The Makefile's
`libsqlite` target then compiles them into
`build/lib/libsqlite3.dylib` (macOS) or `build/lib/libsqlite3.so` (Linux).

To upgrade SQLite, update the version/year/checksum in `scripts/fetch-sqlite.sh`
and this file, then delete the gitignored sources and re-run the script.
