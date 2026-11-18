# Library Demo

Demonstrates building an AXYON library package with C-ABI exports.

## Features

- `[lib]` manifest section with multiple `crate_type` values
- `@export_c` decorator for C-ABI function exports
- Internal helper functions (not exported)

## Build

```bash
axyon build
```

This produces two artifacts:

| Artifact | Description |
|----------|-------------|
| `library_demo.axc` | AXYON crate bundle (for use by other AXYON packages) |
| `liblibrary_demo.a` | Native static archive (for linking from C/C++) |

## Using from C

```c
#include <stdint.h>
#include <stdio.h>

// Declare the exported functions
int32_t add_i32(int32_t a, int32_t b);
int32_t sub_i32(int32_t a, int32_t b);
int32_t mul_i32(int32_t a, int32_t b);
int32_t square_i32(int32_t x);

int main() {
    printf("add:    %d\n", add_i32(10, 20));     // 30
    printf("sub:    %d\n", sub_i32(50, 8));      // 42
    printf("mul:    %d\n", mul_i32(6, 7));       // 42
    printf("square: %d\n", square_i32(7));       // 49
    return 0;
}
```

Link with:
```bash
cc -o demo main.c -L target/debug -llibrary_demo -laxyon_rt
```
