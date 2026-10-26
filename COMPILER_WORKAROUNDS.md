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

**Status.** The recheck passes on `nightly-2026-10-21-5349569`, so this
workaround can go.

## 2. A component with neither method annotated hangs the compiler

**Status.** Fixed. This affected the compiler that roc-ray 0.10.0 pinned
(`nightly-2026-09-27-a3ce7f1`). roc-ray 0.11 pins no compiler, and on
`nightly-2026-10-21-5349569` the recheck below finishes in under a second
with no errors, so the annotations can go. `examples/sample.roc`, which has
no platform, already leaves both methods unannotated.

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

## 3. A generic function's error union does not widen through a closure

**What fails.** An annotated function can return a narrower error union than
its caller declares, and `?` widens it. That stops working when the function
is generic and is called from a closure handed to another function:

```roc
Fault : [OutOfBounds, WrongColumn, TooManyEntities]

grow : Column(col), Column(col) -> Try(Column(col), [WrongColumn])

append : List(Column(col)), Column(col) -> Try(List(Column(col)), Fault)
append = |columns, cell| Ok(columns.map_try(|column| grow(column, cell))?)
# This expression produces the tag OutOfBounds but the annotated tag union
# does not list it.
```

The same code checks when `grow` is not generic (`U64 -> Try(U64,
[WrongColumn])`), and wrapping the call as `|column| Ok(grow(column, cell)?)`
does not help.

**Workaround.** Everything that changes a world returns the one `Fault` union,
including the closures in `Column`, so nothing has to widen. `grow` returns
`Try(Column(col), Fault)` although the only fault it can produce is
`WrongColumn`.

**Recheck.** Change `grow`'s annotation in `package/Ecs.roc` to end in
`[WrongColumn]` and run `roc check package/main.roc`. If it passes, the helpers
can go back to listing only the errors they can produce.

## 4. Static dispatch on a type variable crashes inside a closure passed along

**What fails.** In `World.take`, this checked but crashed when the test ran,
with `dispatch on a value that can never exist`:

```roc
take = |World.(world), entity| {
    C : c
    ...
    without = |row| row.drop_if(|cell| C.from_col(cell.data).is_ok())
    moved = sound(migrate(world.archetypes, world.slots, entity, seat, without))
```

**Workaround.** `take` builds a `Column` from the component it took and uses
its `matches` closure, which was made where the type was known.

It also happens outside `Ecs.roc`. In `bench/ops.roc`, a map through
`world.select().without(Tag.to_col)` in a closure handed to the `moved` helper
crashes the same way, both with `world.map_with_in(selection, fn)` and with
the `selection.map_with(fn).apply_to(world)` API that came before it. With
`having(Pos.to_col)` in its place, or with no filter, it runs. A smaller app
that hands the same call to a one-line `apply = |world, f| f(world)` does not
crash, so what triggers it is not yet pinned down.

**Recheck.** Put the `C.from_col` version back and run
`roc test package/main.roc`. For the second case, put `without(Tag.to_col)`
back in the `map_in` workload and run `roc test bench/ops.roc`.

## 5. A parameter of unknown type has one signature per method

**What fails.** When a function's parameter has no annotation, every method
called on it must have the same type everywhere in that function, including
inside the helpers it is passed to. `World.get` and `World.resource` return
whichever type the caller expects, so two calls that want different types
conflict. This was observed on `nightly-2026-10-21-5349569`; older compilers
accepted it:

```roc
layer_of = |world, entity| match world.get(entity) { Ok(Layer.(l)) => l, Err(_) => 0 }
labels = |world| world.query3().map(
    |(entity, ...)| (layer_of(world, entity), match world.get(entity) { Ok(TextAlign.(a)) => ... }),
)
# requires its type to have two different, incompatible get methods
```

**Workaround.** In helpers that call one of these methods, use the qualified
name, `Ecs.World.get(world, entity)` or `Ecs.World.resource(world)`. That fixes
`world` to an `Ecs.World` and the method stays polymorphic. `RayEcs.layer_of`,
`RayEcs.border_width` and `RayEcs.labels` do this, as do `seconds`, `held` and
`pressed` in `asteroids.roc`.

**Recheck.** Change `Ecs.World.get(world, entity)` in `RayEcs.layer_of` back
to `world.get(entity)` and run `roc check examples/RayEcs.roc`.
