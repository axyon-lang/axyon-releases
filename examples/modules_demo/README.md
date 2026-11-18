# Modules Demo

This example demonstrates AXYON's module system with Python-style decorator syntax.

## Project Structure

```
modules_demo/
├── axyon.toml
├── README.md
└── src/
    ├── __init__.axpy          # Root package: declares submodules and re-exports
    └── math/
        ├── __init__.axpy      # Math package: @public from . import vector; from . import internal
        ├── kinds.axpy         # Public: enum, generic enum, trait, const and type alias
        ├── vector.axpy        # Public: Vec3 struct and vector operations
        └── internal.axpy      # Private: internal helper functions
```

## Module System Features

### 1. Module Declarations (`__init__.axpy`)

Each package has an `__init__.axpy` file that declares its submodules:

```python
# In src/__init__.axpy
@public from . import math      # Public submodule - accessible from outside

# In src/math/__init__.axpy
@public from . import vector    # Public - can be imported as math.vector
from . import internal          # Private - only visible within math package
```

### 2. Visibility Modifiers

Items are **private by default**:

```python
# Public items - can be imported from other modules
@public
struct Vec3:
    pub x: f32    # Public field
    y: f32        # Private field (default)

@public
def dot(a: Vec3, b: Vec3) -> "f32":
    ...

# Internal items - accessible within the same package root (like pub(crate) in Rust)
@internal
def package_helper() -> "i32":
    ...

# Private items - only visible in this module
def _helper() -> "f32":
    ...
```

### 3. Re-exports (`@public from ... import`)

Re-export items from submodules for convenient access:

```python
# In src/__init__.axpy
@public from math.vector import Vec3
@public from math.vector import dot

# Now users can import directly:
# from modules_demo import Vec3, dot
# Instead of:
# from modules_demo.math.vector import Vec3, dot
```

### 4. Import Syntax

```python
# Import entire module
import math.vector as vec

# Import specific items
from math.vector import Vec3, dot

# Import submodule
from math import vector
```

## Building

```bash
cd examples/modules_demo
axyon build
```

## Output

The compiled MLIR is written to:
```
target/axyon/modules_demo/debug/module.mlir
```

### Module-qualified type annotations

`main.axpy` imports `vector` and `kinds` and annotates with `vector.Vec3` and
`kinds.Length`; these are the same types as the bare imported names.

### Module-qualified values

`vector.Vec3 { x: 2.0, y: 0.0, z: 0.0 }` and `kinds.Axis.Z` build the same
values as the bare spellings (`Vec3 { .. }`, `Axis.Z`); the demo prints the
literal's `x` (2) and asserts it. A local or constant that shadows the
resolved bare type name (e.g. a parameter named `Vec3`) is rejected with a
spanned diagnostic.
