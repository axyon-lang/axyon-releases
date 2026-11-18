# Launching a dependency's CUDA kernels

A workspace whose executable launches `@gpu(entry)` kernels defined in a
sibling library (issue #2663).

```
cuda_dependency_kernel/
  axyon.toml            # [workspace] members = ["kernels", "app"]
  kernels/
    axyon.toml          # library, [target] gpu = ["nvptx-sm80"]
    src/__init__.axpy   # @public @gpu(entry) saxpy, square_plus
  app/
    axyon.toml          # executable, depends on kernels by path
    src/main.axpy       # from kernels import saxpy, square_plus; gpu_launch(...)
```

`kernels` compiles its kernels into its own device image
(`axyon_cuda_kernel_image__kernels`), which its object defines. `app` imports
the kernels like functions and launches them with `gpu_launch`; each launch
names the image of `kernels`, and the executable links the library's object.
`app` defines no kernel, so its module has no `gpu.module` of its own.

The program checks every lane of each launch against a host reference
(exactly, for `i32` and `f32`), over lengths 0, 1, 128, 300 and 1000, and
prints `... all lengths match the host reference`.

## Building and running

It needs the MLIR/LLVM toolchain and a CUDA device:

```bash
axyon build            # or: axyon build --release
./target/debug/app
```

Set `AXYON_GPU_LAUNCH_EVIDENCE=1` to see each launch's device and image.
Without a CUDA device the first device allocation stops the program with an
AXYON panic; there is no CPU fallback.

## Limitations

See `docs/known-limitations/2663-imported-kernel-launch.md`: launch an
imported kernel under its own name and from the module that defines it
(no import aliases; #2737 tracks module-qualified resolution), and link the
defining package's object (a `dylib` alone does not export the image).
