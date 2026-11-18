# rest_api: a small REST service as a language probe (#3523)

A blocking HTTP/1.1 server, a router, a JSON codec and an in-memory CRUD
app, written in AXYON using only what is on `main`. Like the ML PoC does
for ML, it probes the language and stdlib end to end for a typical
service. The gaps it hit are listed at the end.

The workspace has two packages:

| Package | Kind | Contents |
|---------|------|----------|
| `http/` | library | `request` (HTTP/1.1 parser and size limits), `response` (status line, headers, body), `router` (method + path with `:id` parameters, 404/405/500), `server` (blocking accept loop on `std.net.TcpListener`), `json` (value type, encoder, decoder), `testing` (loopback round-trip helpers) |
| `todo_api/` | binary | `todos` (in-memory store and the CRUD handlers), `checks` (self-test over loopback TCP), `main` (port from argument or env) |

`todo_api` depends on `http` through a path dependency
(`http = { path = "../http" }`).

## Running

```bash
cd examples/rest_api
axyon build                                  # builds both members
./target/debug/todo_api 8080                 # port as the first argument
TODO_API_PORT=8080 ./target/debug/todo_api   # or from the environment
./target/debug/todo_api --self-test          # CRUD checks over loopback, then exit
```

The server listens on `127.0.0.1` only, answers one request per connection
(`Connection: close`) and runs until killed.

```bash
curl -i -X POST -d '{"title":"milk","done":false}' http://127.0.0.1:8080/todos
curl http://127.0.0.1:8080/todos
curl -X PUT -d '{"title":"milk","done":true}' http://127.0.0.1:8080/todos/1
curl -X DELETE http://127.0.0.1:8080/todos/1
```

| Route | Success | Errors |
|-------|---------|--------|
| `GET /todos` | 200, JSON array | |
| `GET /todos/:id` | 200, JSON object | 404 unknown or invalid id |
| `POST /todos` | 201, the created todo | 400 malformed JSON or fields |
| `PUT /todos/:id` | 200, the replaced todo | 404 unknown or invalid id, 400 malformed JSON or fields |
| `DELETE /todos/:id` | 204 | 404 unknown or invalid id |

Any other method on a known path is a 405 with an `Allow` header, an unknown
path is a 404, and a handler error is a 500. A malformed request is a 400;
a head over 8 KiB is a 431 and a body over 64 KiB is a 413
(`http.request.default_limits`).

## Tests

```bash
cd examples/rest_api/http && axyon test
```

- `tests/test_json.axpy`: encoder and decoder round trips, escapes and
  `\u` sequences, numbers, nesting, and malformed input (truncated values,
  bad escapes, trailing characters, nesting depth).
- `tests/test_request.axpy`: request line, headers, `Content-Length` body,
  and malformed or oversized requests.
- `tests/test_router.axpy`: path parameters, 404 against 405 and `Allow`,
  and handler errors as 500.
- `tests/test_server.axpy`: real TCP round trips on a listener bound to
  `127.0.0.1:0` (an OS-assigned port, never a fixed one); one thread plays
  client and server (see `http/src/testing.axpy`). No external network.

The app's CRUD flow is checked by `todo_api --self-test` (also over
loopback TCP), not by `axyon test`: `axyon test` cannot yet test this
binary package (#3545, #3554, #3555). `examples/build_all.sh --run` (the
CI examples job) builds the workspace, runs `todo_api` with the arguments
in `.run-args` and runs `axyon test` in each member listed in
`.test-members` (#3553: `axyon test` does not run at a workspace root).

## What works

Plain structs, enums and recursive enums (the JSON value type), `Vec` and
`String` building, `Result` with `?` in straight-line code, generic structs
and functions across a path dependency (`Router[S]`, `serve[S]`), `fn`
pointers stored in a generic struct, `std.net` TCP listen/accept/connect on
loopback, `std.env` arguments and variables, `std.strconv` number parsing,
and `format!`. The server, router and codec needed no unsafe code or FFI.

## Gaps found

Each workaround in the sources carries a comment naming the issue it waits
on.

| Issue | Kind | Gap | Workaround here |
|-------|------|-----|-----------------|
| #3532 | bug | AX0918 internal error on `if b:` for a `bool` bound by a match through a reference | `if *b:` |
| #3533 | bug | `return None_` after `from std.core import None_` is AX0381 | `return Option.None_` |
| #3534 | bug | `axyon test` reports a `@test` returning non-zero as passing | tests fail through `assert!` |
| #3535 | bug | `?` followed by a partial move of the unwrapped value fails MLIR emission | `match` instead of `?` |
| #3536 | bug | `match &expr:` is a syntax error | bind a reference first |
| #3537 | bug | `Json.Obj(Vec.new())` cannot infer the element type | annotated local |
| #3538 | bug | a `String` field of a generic struct is not a string inside the generic impl | bind a `&String` to the field first |
| #3539 | bug | false "expected X, found X" binding a generic struct's fn-pointer field | call the field directly |
| #3540 | bug | match-bound local passed to a method in a dependency's generic fn fails monomorphization (AX0815) | move the request into a `let` first |
| #3541 | bug | dependency's generic fn calling its own `write_all` binds std.io_core's | `send_all` instead of `write_all` |
| #3542 | bug | internal error matching a dependency's `Result[E, Err]` with recursive `E` | `JsonDecoded` struct (`decode_value`) |
| #3543 | bug | dependency type's `mut self` method with a `String` argument keeps the receiver borrowed | free function |
| #3544 | bug | dependency's generic method returning a struct with `String` data is a false AX0528 | `Response` keeps header lines as bytes; matches returned, not written to a `&mut` out-parameter |
| #3545 | bug | `axyon test` AX331 clash when package and path dependency both use std.strconv | self-test instead |
| #3557 | bug | a user item named like a private stdlib item (`bytes_equal`, `Header`) is an internal error / AX331 with a prebuilt sysroot | renamed (`same_bytes`, `HeaderField`, `JsonDecoded`) |
| #3546 | enhancement | diverging (`return`) arms in a value-position `match` | placeholder then assign |
| #3547 | enhancement | `?` inside `if`/`for`/`while`/`with` bodies | explicit `match` |
| #3548 | enhancement | `const` array lookup tables | `hex_digit` function |
| #3549 | enhancement | `Vec.remove(i)` / `get_mut(i)`, `pop()` through `&mut Vec` | shift down, then `pop` through the owning struct |
| #3550 | enhancement | capturing closures as handlers | router generic over a state `S` |
| #3551 | enhancement | derive-based JSON (de)serialization | hand-written `todo_json` / `parse_input` |
| #3552 | enhancement | string/bytes APIs: UTF-8 from bytes, byte literals, literal to `Slice[u8]` parameter | byte constants, `String` parameters |
| #3553 | enhancement | `axyon test` from a workspace root | `.test-members` in the examples job |
| #3554 | enhancement | `axyon test` cannot import a binary package's sibling modules | self-test |
| #3555 | enhancement | test programs owning a dependency's recursive types | self-test |

Follow-ups filed from these: #3560 (user-defined derives, toward #3551) and
#3577 (store capturing `dyn fn` handlers once closures land, #3550).
