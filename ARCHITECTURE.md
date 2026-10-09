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
