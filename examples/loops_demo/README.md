# Loops Demo

This example demonstrates all loop constructs in AXYON:

## Features

### 1. Basic For Loop
```python
def sum_to_n(n: i64) -> i64:
    let mut total: i64 = 0
    for i in range(n):
        total += i
    return total
```

### 2. For Loop with Step
```python
def sum_evens(n: i64) -> i64:
    let mut total: i64 = 0
    for i in range(0, n, 2):  # Iterate with step of 2
        total += i
    return total
```

### 3. While Loop
```python
def countdown(start: i64) -> i64:
    let mut x: i64 = start
    while x > 0:
        x -= 1
    return x
```

### 4. Loop Unrolling Decorator
```python
def process_unrolled(n: i64) -> i64:
    let mut total: i64 = 0
    @unroll(4)  # Hint to unroll loop by factor of 4
    for i in range(n):
        total += i
    return total
```

### 5. Print Output
```python
println!("Hello, loops!")
```

## Building

```bash
# Build to MLIR
./build.sh

# Show generated MLIR
./build.sh mlir

# Build executable (requires LLVM)
./build.sh exe

# Build and run
./build.sh run

# Clean
./build.sh clean
```

## Generated MLIR

The loops compile to MLIR's Structured Control Flow (SCF) dialect:

- `for` loops → `scf.for`
- `while` loops → `scf.while`
- `@unroll(N)` → Comment hint for optimization passes

## Requirements

- Rust toolchain (for AXYON compiler)
- LLVM 17+ (for executable generation)
