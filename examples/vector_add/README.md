# Vector Add Example

This example demonstrates how to initialize two f32 vectors of size 100 and add them together using AXYON's tensor operations.

## Source Code

```python
import tensor as T

def main() -> i32:
    println!("Vector Add Example")
    println!("Creating two f32 vectors of size 100...")

    # Create vectors
    let a: Tensor[f32, (100,)] = T.zeros([100])
    let b: Tensor[f32, (100,)] = T.ones([100])

    # Add them together
    let c: Tensor[f32, (100,)] = T.add(a, b)

    println!("Done! Result is a tensor where each element is 1.0 (0 + 1 = 1)")
    return 0
```

## Building

```bash
# Build the example (generates MLIR)
./build.sh

# Or use axyon directly
axyon build --emit mlir

# Clean build artifacts
./build.sh clean
```

## What it demonstrates

- **Tensor creation**: Using `T.zeros()` and `T.ones()` to create tensors
- **Static shapes**: Tensors with fixed size `(100,)`
- **Element types**: Using `f32` (32-bit float) element type
- **Elementwise operations**: Using `T.add()` for vector addition
- **Type annotations**: Explicit tensor type annotations with shape and dtype
- **Debug macros**: Using `println!()` for output

## Generated MLIR

The compiler generates MLIR using the `linalg.generic` operation for the elementwise addition:

```mlir
func.func @main() -> i32 {
    // println! calls
    func.call @axyon_rt_println(%0, %1) : (!llvm.ptr, i64) -> ()

    // Create zeros tensor (placeholder)
    %4 = /* zeros */

    // Create ones tensor (placeholder)
    %5 = /* ones */

    // Elementwise addition using linalg.generic
    %6 = linalg.generic {
        indexing_maps = [
            affine_map<(d0) -> (d0)>,
            affine_map<(d0) -> (d0)>,
            affine_map<(d0) -> (d0)>
        ],
        iterator_types = ["parallel"]
    } ins(%4, %5 : tensor<*xf32>, tensor<*xf32>) outs(%7 : tensor<*xf32>) {
        ^bb0(%in0: f32, %in1: f32, %out: f32):
            %result = arith.addf %in0, %in1 : f32
            linalg.yield %result : f32
    } -> tensor<*xf32>

    return %11 : i32
}
```

## Notes

- `T.zeros()` and `T.ones()` are placeholders - tensor creation ops will be fully implemented in a future release
- The `linalg.generic` operation expresses the parallel elementwise add
- String constants are stored as LLVM globals and printed via runtime functions
