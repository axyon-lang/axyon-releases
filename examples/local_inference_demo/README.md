# local_inference_demo

Experimental checked local type inference (issue #805). The package sets
`[build] local_inference = true`: a `let` may omit its type when the
initializer fully determines it, and a type that would only come from a
literal default (`let r = 0.5`) is rejected with `AX0818` instead.

```bash
axyon run          # the switch is on through axyon.toml
axyon check        # same, without code generation
```

See the [Local Type Inference](../../docs/src/guide/local-inference.md) guide.
