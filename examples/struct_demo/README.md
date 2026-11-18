# Struct Demo Example

This example demonstrates user-defined struct types in AXYON.

## Features Demonstrated

- **Struct definitions** with `struct Name:` syntax
- **Public fields** with `pub` visibility
- **Struct literals** with `Point { x: 1.0, y: 2.0 }` syntax
- **Field access** with `point.x` syntax

## Source Code

```python
# Define a Point struct with two f32 fields
struct Point:
    pub x: f32
    pub y: f32

def main() -> i32:
    # Create a point using struct literal syntax
    let p: Point = Point { x: 3.0, y: 4.0 }

    # Access fields
    let x_coord: f32 = p.x
    let y_coord: f32 = p.y

    return 0
```

## Building

### Quick Start

```bash
# Build to MLIR (no LLVM required)
./build.sh

# Build executable (requires LLVM)
./build.sh exe

# Build and run
./build.sh run
```

### Build Commands

| Command | Description |
|---------|-------------|
| `./build.sh` or `./build.sh build` | Compile to MLIR |
| `./build.sh exe` | Compile to executable (requires LLVM) |
| `./build.sh run` | Build and run the executable |
| `./build.sh clean` | Remove build artifacts |
| `./build.sh check` | Check for errors without building |
| `./build.sh mlir` | Build and display generated MLIR |

### Requirements

- **Rust toolchain** (for building the AXYON compiler)
- **LLVM 17+** (for building executables)

Set the `AXYON_LLVM_BIN` environment variable if LLVM is not in a standard location:

```bash
export AXYON_LLVM_BIN=/path/to/llvm/bin
./build.sh exe
```

## Generated Output

After building, you'll find:

```
target/axyon/struct_demo/debug/
└── module.mlir      # High-level MLIR

target/debug/
└── struct_demo      # Executable (with --emit exe)
```

Intermediate files (`module.llvm.mlir`, `module.ll`, `module.o`) are written to
a per-invocation temporary directory and deleted automatically after linking, so
they do not appear in the source tree.

## MLIR Output

The struct operations are lowered to LLVM dialect:

```mlir
// Create struct with undef + insertvalue
%0 = llvm.mlir.undef : !llvm.struct<(f32, f32)>
%1 = llvm.insertvalue %3, %0[0] : !llvm.struct<(f32, f32)>
%2 = llvm.insertvalue %5, %1[1] : !llvm.struct<(f32, f32)>

// Access field with extractvalue
%3 = llvm.extractvalue %2[0] : !llvm.struct<(f32, f32)>
```

## Current Limitations

- User-defined function calls are not yet supported
- Nested struct types require manual type annotations
