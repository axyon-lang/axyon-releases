# Private Helpers Demo

Two modules each define a private `helper()`. Private, non-generic functions
are module-local: at package merge time the compiler module-qualifies a
function whose name another module also emits (`private_helpers_demo_util__helper`)
and rewrites the calls inside its own module, so the names never clash.
Public functions still share one package-wide namespace (two public
`helper`s are `AX331`). See the
[Modules guide](../../docs/src/guide/modules.md#one-function-namespace-per-package).

```
cd examples/private_helpers_demo && axyon run
```
