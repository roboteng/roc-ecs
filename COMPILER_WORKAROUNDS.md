# Compiler workarounds

Places where the code is shaped by what the Roc compiler accepts rather than by
what would read best. Unless an entry names a different compiler, everything
here was observed on `release-safe-fd6625e8`; when the compiler moves on, each
entry says how to check whether the workaround can go.

## 1. A nominal type cannot be pattern-matched outside its own module

**What fails.** `Name.(inner)` as a pattern is only accepted in the module that
defines `Name`. Anywhere else it is rejected with `The type Name is not
declared in this scope`, even though the same `Name.(value)` is accepted as an
expression. All of these were tried from another module and all fail:

```roc
f = |Lib.Inner.(r)| r.x                 # qualified, lambda argument
f = |v| match v { Lib.Inner.(r) => r.x } # qualified, match branch
Lib.Inner.(r) = v                        # qualified, destructuring statement
import Lib exposing [Inner]
f = |Inner.(r)| r.x                      # exposed name
Mine : Lib.Inner
f = |Mine.(r)| r.x                       # local alias ("it is an alias")
import Top
f = |Top.(r)| r.x                        # a module's own top-level type
```

**Why it matters here.** `Ecs` picks which component a query or map touches
from the types of the closure's arguments, and a pattern such as
`|Pos.(p), Vel.(v)|` is the natural way to state them. That works inside
`Ecs.roc` and `RayEcs.roc` for their own types, but `examples/ray-basics.roc`
cannot write `|Position.(p)|` for a `RayEcs` component.

**Workarounds.**

- Every component in `RayEcs.roc` has a `get` that returns what it wraps:
  `Radius.get(radius)`, or `radius.get()` once the type is known.
- App-side closures bind the whole component and let something else pin its
  type. Constructing the result is usually enough:

  ```roc
  # `Position.(...)` pins the first argument, the local `Follower.(_)` pattern the second
  world.map_with(|_position, Follower.(_)| Position.(pointer.position()))
  ```

- Components defined in `ray-basics.roc` (`Follower`, `Accent`, `Pulse`) are matched
  with patterns as usual, since they are local.

**Recheck.** Put `f = |RayEcs.Radius.(r)| r` in `examples/ray-basics.roc` and
run `roc check examples/ray-basics.roc`. If it passes, the `get` functions and
the `_position` style arguments can be replaced with patterns.

## 2. A method cannot be called on a value whose type is not known yet

**What fails.** `value.method()` needs the type of `value` to already be
resolved. `World.single` and `World.get` return whichever component the caller
expects, so calling a method on their result directly gives the compiler
nothing to go on:

```roc
match world.single() {
    Ok(pointer) => ... pointer.position() ...
}
# This is trying to dispatch a method named from_col on an unresolved type variable
```

**Workarounds.** Either of these was confirmed to compile:

```roc
# annotate the result first (what ray-basics.roc does)
found : Try(Pointer, _)
found = world.single()

# or call the function by its qualified name instead of as a method
match world.single() {
    Ok(pointer) => ... Pointer.position(pointer) ...
}
```

This one is how static dispatch is specified rather than a bug, so it is
unlikely to change.

## 3. Effectful functions cannot be called from `expect`

**What fails.** An `expect` cannot call a function with `=>` in its type, and
`Draw.Frame` only exists inside `render!`. This is stated in the RocRay
platform's own documentation (`App.Input.for_tests`); it was not probed
separately here.

**Workaround.** The logic lives in pure functions and the effectful ones are
thin shells around them:

| Effectful             | Pure, tested with `expect`                            |
| --------------------- | ----------------------------------------------------- |
| `RayEcs.draw!`        | `RayEcs.scene`, which returns every draw call as data |
| `RayEcs.read_devices` | `RayEcs.write_devices`                                |

Nothing asserts that `draw!` issues the calls `scene` returns; that part is
only exercised by running the app.

## 4. A component with neither method annotated hangs the compiler

**Status.** This affects the compiler that roc-ray 0.10.0 pins
(`nightly-2026-09-27-a3ce7f1`), so the examples that run on RocRay keep the
workaround. It is fixed in the compiler we currently build with: on
`nightly-2026-10-06-c34079d` the recheck below finishes in about 3s with no
errors and the tests pass, and `examples/sample.roc`, which has no platform,
already leaves both methods unannotated.

**What fails.** A component's `to_col` and `from_col` can each be inferred, but
not both at once. With `Follower` in `ray-basics.roc` as the test case:

| Annotations on `Follower` | Result                                                                                              |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| both                      | checks, tests pass                                                                                  |
| `to_col` only             | checks, tests pass                                                                                  |
| `from_col` only           | checks, tests pass                                                                                  |
| neither                   | `roc check examples/ray-basics.roc` does not finish (stopped after 35s; it normally takes about 4s) |

There is no error message; the compiler just never returns.

**Workaround.** Every component keeps the annotation on `to_col` and leaves
`from_col` to be inferred, since `from_col`'s is the longer of the two:

```roc
Follower := {}.{
    to_col : List(Follower) -> [Followers(List(Follower))]
    to_col = |list| Followers(list)

    from_col = |col| match col {
        Followers(list) => Ok(list)
        _ => Err(WrongColumn)
    }
}
```

If `roc check` ever seems stuck after adding a component, a missing `to_col`
annotation is the first thing to look for.

**Recheck.** Remove the `to_col` annotation from `Follower` in
`examples/ray-basics.roc` and run `roc check examples/ray-basics.roc` with a time limit. If it finishes, both annotations
are optional.
