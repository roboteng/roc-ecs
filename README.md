An archetypal ECS implementation in Roc.

`roc run examples/asteroids.roc`

- Entity : a reference to a collection of zero or more Components
- Component : a piece of data, like Position, Health, or an image
- System : a function that reads or modifies Components on matching Entities

## Goals

- Achieve a Bevy-like API and performance, all while in pure safe Roc.
- Use the type inference of Roc, instead of Rust macros
- Take advantage of Roc's optimistic mutation, when possible, to avoid excessive allocations

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md)

## Example

[examples/sample.roc](examples/sample.roc)

[examples/RayEcs.roc](examples/RayEcs.roc) shows one option of how you might allow the ECS world to talk with the outside world, and do IO.
As of right now, it doesn't seem useful to include effectful functions in the base package.
