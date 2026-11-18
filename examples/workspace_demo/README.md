# Workspace Demo

Demonstrates AXYON's workspace-of-crates model, where a single
workspace manifest groups multiple crates that are compiled in
dependency order.

## Structure

```
workspace_demo/
  axyon.toml          # [workspace] root — lists members
  mathlib/
    axyon.toml        # [package] library crate
    src/
      __init__.axpy   # Library root — re-exports public API
      geometry.axpy   # Circle/rectangle area helpers
      arithmetic.axpy # Clamp/abs_diff helpers
  app/
    axyon.toml        # [package] binary crate, depends on mathlib
    src/
      main.axpy       # Entry point — imports from mathlib
```

## Workspace Manifest

The root `axyon.toml` declares workspace members and their build order:

```toml
[workspace]
members = ["mathlib", "app"]
```

Each member has its own `axyon.toml` with `[package]` and optional
`[dependencies]` sections. Dependencies between members are resolved
via the workspace graph to produce a topological build order.

## Building

Build each member individually:

```bash
# Build the library
cd mathlib && axyon build

# Build the app (depends on mathlib)
cd app && axyon build
```

The workspace build order (`mathlib` -> `app`) is determined
automatically from declared dependencies.
