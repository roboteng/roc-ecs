An ECS implementation in Roc.

Run the examples with `roc run examples/main.roc` or
`roc run examples/asteroids.roc`, using the compiler version pinned by RocRay.

## Package imports

Add `ecs: "../package/main.roc"` to your app header (adjust the path for your
project), alongside your platform, then import `ecs.Ecs` and `ecs.RayEcs`.
The package itself has no platform dependencies.

## Connecting RayEcs to RocRay

The app imports RocRay and supplies its initial devices and a drawing callback:

```roc
world = RayEcs.default(scene(font), {
    devices: Devices.none,
    draw!: draw_command!,
})
```

`draw_command!` receives the frame and one command from `RayEcs.scene`, and
returns `Try({}, error)`. It dispatches gradient rectangles, gradient circles,
rectangles, rounded rectangles, circles, text and FPS commands to the platform.
Both examples include the complete adapter. Drawing errors propagate through
`RayEcs.render!`.

`RayEcs.update!` accepts input with `devices` and `time.elapsed_seconds` fields.
The device snapshot has a `mouse` field. Pointer and keyboard convenience
methods delegate to the supplied snapshots' methods. For custom setups, use
`RayEcs.new(world)` and register input/output systems yourself, or call
`RayEcs.spawn_devices(world, devices)` directly.

World annotations now take the host types explicitly:

```roc
Model(c) : { world : RayEcs.World(c, App.Input(Msg), Draw.Frame, [Exit(I64)]) }
```

Components wrapping platform values are generic: `Pointer(mouse)`,
`Keyboard(devices)`, `Label(font)`, and the color components such as
`FillColor(color)`. Construction stays the same (`FillColor.(Color.blue)`);
use `Pointer(_)` or `Keyboard(_)` when an annotation should infer the host type.

The core and scene tests run without RocRay:

```sh
roc test package/Ecs.roc
roc test package/RayEcs.roc
```

## Goals

- Achieve a Bevy-like API and performance, all while in pure safe Roc.
- Use Roc's type inference instead of Rust macros.
