I assume you are familiar with ECS in general, otherwise https://github.com/SanderMertens/ecs-faq#what-is-ecs is a good overview.

## Core structure

One of the core challenges I ran into is how to do type erasure. This is because:

- Components are different types
- Archetypes hold List of Components
- Archetypes are stored in a List, so they must be the same type.

The 'trick' here is that each Component knows:

- How to turn itself into a Column
- How to check if a given Column is its type

Archetypes are generic over the set of Columns that it could store.
The type for the set of Columns is something like this:

```roc
Columns : [
    Positions(List(Position)),
    Armors(List(Armor)),
    ..
]
```

This means that when an Archetype stores a `List(Column)`, it's storing the discriminant for which specific column it is, as well as the usual List items of data pointer, size, and capacity.
Since each Column and the Entity List should all be modified together, we could store the size and capacity once, instead of per list. I haven't yet figured out a way to do that in Roc.

This allows us to write a query, asking for a Component type(s), and we can ask the archetypes at runtime for the Columns they store.

## Principles

Two rules shape the internals of `Ecs.roc`. They pull against each other in places, and the second half of this section is about where.

### 1. Lean into errors

A helper that cannot do what it was asked returns an error. It does not hand back its input unchanged.

Handing the input back looks harmless, but it means the caller has to already know the call will work, usually by checking first and then passing along something that _shouldn't_ fail. If the check and the action ever disagree, nothing notices, and the world is quietly wrong. So instead of asking "does this match?" and then acting on the answer, we try the thing, and the result is either what we need for the next step or the reason there isn't one.

There are three kinds of error, and each has one place it ends up:

| Kind | Examples | Where it goes |
| --- | --- | --- |
| The caller's | `NoSuchEntity`, `MissingComponent` | Returned from the public function. |
| "Not this one" | `ShapeMismatch`, `Missing`, `NoFit`, `NotFound` | Matched by the caller, which moves on: the next archetype, a new archetype, skipping this archetype in a query. These are matched by name, never with `_`, so no other error can be swallowed along with them. |
| A `Fault` | `OutOfBounds`, `WrongColumn`, `TooManyEntities` | The world's bookkeeping disagrees with itself, which no caller can cause. It propagates with `?` up to the public function, where `sound` crashes with the fault's name. |

Spawning shows all of it. `line_up` tries a row against an archetype's columns and returns either the row's cells in that archetype's column order or `ShapeMismatch`. `find_fit` goes on to the next archetype after a mismatch. `place` appends to the archetype that fit, or, on `NoFit`, makes a new archetype out of the row itself, so it always has somewhere to put the entity. Anything that goes wrong after that is a `Fault`.

Things that follow from this:

- A function that looks something up returns what the next step needs, not a `Bool`. `line_up` returns the lined-up row; `locate` returns the `Seat`.
- Where a builtin gives back its input for a bad argument, we check first and return the error ourselves. `List.drop_swap` with a row the list doesn't have is the one case so far.
- The public signatures did not change. `spawn` still cannot fail from the caller's point of view, because the only ways it can fail are faults.

### 2. Measure, and write for opportunistic mutation

Roc updates a list in place when nothing else refers to it, and copies it otherwise. Nothing in the source says which one happened, and the tests pass either way. The difference is whether spawning an entity costs the same in a world of a million as in a world of ten.

So this is measured, not reasoned about:

```
python3 bench/scaling.py
```

runs each operation on every entity of worlds of doubling size and reports how the total grows. Twice the entities taking twice as long means the operation is constant time. Four times as long means something the size of the world is copied on every call.

On `nightly-2026-10-06-c34079d`, at the largest size each side finished within the time budget (32,000 entities before, 512,000 after):

| Operation | Before: time ~ n^ | per entity | After: time ~ n^ | per entity |
| --- | --- | --- | --- | --- |
| `spawn` | 1.84 | 57,693ns | 0.96 | 962ns |
| `despawn` | 1.97 | 76,323ns | 1.15 | 309ns |
| despawn then spawn | 2.00 | 102,650ns | 0.97 | 1,174ns |
| `insert`, replacing | 1.74 | 17,974ns | 1.25 | 414ns |
| `insert`, adding | 1.75 | 86,201ns | 0.94 | 1,731ns |
| `insert` then `take` | 1.87 | 88,513ns | 0.93 | 3,064ns |

`get` and the `map` functions were already linear and still are. A `map` still allocates a new list for each column it writes: a `Selection` shares its archetypes with the `World` it came from, so there is never only one reference to them. Making that in place would need a change to the `Selection` API.

What the compiler turned out to need, each found by changing one thing and running the benchmark again. These are facts about that compiler version, not about Roc, so re-measure before relying on them:

- **To change a list element with a function that can fail, take it out of the list first.** `try_update` does this with `List.replace`, which swaps a spare in and hands the element back with nothing else pointing at it. `List.map_try`, `List.fold_try`, `List.map2`, and `List.map` followed by collecting the results all leave the element shared with the list, and the element is then copied when it is changed. In a test that appended to two columns 40,000 times, those took about 3.8s and `List.replace` took 16ms.
- **Unwrap the list you are about to change with a `match`, and change it in the `Ok` branch.** In `column_of`, `into = C.from_col(dst)?` followed by `into.concat(from)` copies `into`. The same thing written as `match C.from_col(dst) { Ok(into) => ... }` does not. The other column, the one only being read, can use `?`.
- **Build a spare in a function of its own.** `spare_at` reads a column in order to make an empty one like it. Written inline in the loop that then calls `try_update`, that read leaves a reference to the column behind.
- **Keep a failing branch from referring to the value you passed in.** `match change(world) { Ok(next) => next, Err(_) => world }` needs `world` to still exist after the call, which is a second reference for the whole call. The benchmark's own loop did this at first and made every operation look quadratic.
- **Unwrap `World` in the argument**, as in `|World.(world), entity|`, and pass its lists to helpers one by one.

### Where the two meet

Trying something and carrying on when it fails means the caller still needs the thing it tried on. In Roc that is a second reference, and a second reference means a copy. So "try to append to this archetype, and if it doesn't fit, try the next" cannot be one step that both tests and appends, or every spawn would copy the archetype.

The way out is to split by what can go wrong, not by check and action:

- A failure the caller carries on from happens in a step that only reads, and that step returns what the write needs. `line_up` does not answer "does it fit?". It returns the row in the archetype's column order.
- A step that writes takes its input with nothing else pointing at it, and the only errors it has left are faults. `append_row` can still fail in its type, because a column is type-erased and could in principle be handed the wrong component. If it does, that is reported, not hidden.
