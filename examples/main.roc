app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0/5xecDmRJroKT9fnSiYsGdCKEzNWLnRKGtHJ5CxuCnpb9.tar.zst" }

import rr.App
import rr.Color
import rr.Devices
import rr.Draw
import rr.Text
import Ecs
import RayEcs exposing [Pointer, Keyboard, Clock, Layer, Position, Size, Radius, CornerRadius, FillColor, BorderColor, BorderWidth, Gradient, RadialGradient, Label, TextColor, TextAlign, FpsCounter]

## Everything on screen is an entity in the world: `RayEcs` reads the devices
## into it on every update and draws it on every render.
Model(c) : { world : RayEcs.World(c, Msg, []) }

## Nothing here waits, so there is no task to spawn and no message to fold in.
## An app that reads a file or fetches a URL gives `Msg` the variants those
## tasks answer with; see the `task_sleep` and `async_read` examples.
Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default
		.with_title("Hello RocRay")
		.with_size({ width: 800, height: 600 })
		.with_frame_pacing(Capped(120)),

	|_io| {
		font = Draw.default_font!()
		Ok({
			world: RayEcs.default(
				scene(font)
					.add_system(follow_pointer)
					.add_system(tint_accents)
					.add_system(pulse),
			).add_input(quit_on_escape),
		})
	},
)

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| Ok({ world: RayEcs.update!(model.world, input)? })

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| RayEcs.render!(model.world, frame)

# Scene

blue = Color.from_hex_rgb(0x2f80ed)

red = Color.from_hex_rgb(0xf94144)

green = Color.from_hex_rgb(0x06d6a0)

title = "Roc :heart: Raylib"

at = |x, y| Position.({ x: x, y: y })

## A circle that fades from `color` at this alpha to nothing at its edge.
fading = |color, alpha| RadialGradient.({ inner: Color.with_alpha(color, alpha), outer: Color.with_alpha(color, 0) })

## The entities, back to front.
scene = |font| {
	title_width = font.measure({ text: title, size: 38, spacing: Draw.default_spacing }).width
	Ecs.World.empty()
		.spawn3(at(0, 0), Size.({ width: 800, height: 600 }), Gradient.(TopToBottom(Color.from_hex_rgb(0x131f38), Color.from_hex_rgb(0x070b16))))
	# Two glows on the backdrop; the accent one breathes.
		.spawn(Ecs.Bundle.empty().add(Layer.(1)).add(at(620, 90)).add(Radius.(220)).add(fading(blue, 90)).add(Accent.(90)).add(Pulse.({ base: 220, amount: 40 }))).0
		.spawn4(Layer.(1), at(150, 540), Radius.(260), fading(green, 45))
		.spawn4(Layer.(2), at(0, 0), FpsCounter.(32), TextColor.(Color.white))
	# A soft drop shadow, then the panel itself over the top of it.
		.spawn(Ecs.Bundle.empty().add(Layer.(3)).add(at(126, 160)).add(Size.({ width: 560, height: 300 })).add(CornerRadius.(22)).add(FillColor.(Color.with_alpha(Color.black, 90))).add(BorderColor.(Color.transparent))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(4)).add(at(120, 150)).add(Size.({ width: 560, height: 300 })).add(CornerRadius.(22)).add(FillColor.(Color.from_hex_rgb(0x18243b))).add(BorderColor.(Color.with_alpha(Color.white, 55))).add(BorderWidth.(2))).0
	# The title, a rule under it as wide as the title, and the help line.
		.spawn(Ecs.Bundle.empty().add(Layer.(5)).add(at(400, 230)).add(Label.({ text: title, size: 38, font: font })).add(TextColor.(Color.white)).add(TextAlign.((Top, Center)))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(5)).add(at(400 - title_width * 0.5, 286.5)).add(Size.({ width: title_width, height: 3 })).add(FillColor.(Color.with_alpha(blue, 170))).add(BorderColor.(Color.transparent)).add(Accent.(170))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(5)).add(at(400, 310)).add(Label.({ text: "Move the pointer  -  click for an accent  -  ESC exits", size: 18, font: font })).add(TextColor.(Color.from_hex_rgb(0xa8b4cc))).add(TextAlign.((Top, Center)))).0
	# The pointer: a halo that breathes, a dot, and a faint ring over both.
		.spawn(Ecs.Bundle.empty().add(Layer.(6)).add(at(400, 300)).add(Radius.(26)).add(FillColor.(Color.with_alpha(blue, 40))).add(Accent.(40)).add(Pulse.({ base: 26, amount: 8 })).add(Follower.({}))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(6)).add(at(400, 300)).add(Radius.(18)).add(FillColor.(blue)).add(BorderColor.(Color.white)).add(BorderWidth.(3)).add(Accent.(255)).add(Follower.({}))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(7)).add(at(400, 300)).add(Radius.(32)).add(FillColor.(Color.with_alpha(Color.from_hex_rgb(0x00ff00), 40))).add(Pulse.({ base: 32, amount: 8 })).add(Follower.({}))).0
}

# Systems

## Ends the app when Escape goes down.
quit_on_escape = |world, _input| {
	found : Try(Keyboard, _)
	found = world.inner.single()
	match found {
		Ok(keyboard) if keyboard.pressed(KeyEscape) => Err(Exit(0))
		_ => Ok(world)
	}
}

## Keeps every `Follower` under the pointer.
follow_pointer = |world| {
	found : Try(Pointer, _)
	found = world.single()
	match found {
		Ok(pointer) => world.map_with(|_position, Follower.(_)| Position.(pointer.position()))
		Err(_) => world
	}
}

## Recolors every `Accent`: red while the left button is held, blue otherwise.
tint_accents = |world| {
	found : Try(Pointer, _)
	found = world.single()
	match found {
		Ok(pointer) => {
			accent = if pointer.down(Left) red else blue
			world
				.map_with(|_fill, Accent.(alpha)| FillColor.(Color.with_alpha(accent, alpha)))
				.map_with(|_gradient, Accent.(alpha)| fading(accent, alpha))
		}
		Err(_) => world
	}
}

## One slow sine drives every `Pulse`, so the scene breathes together.
pulse = |world| {
	found : Try(Clock, _)
	found = world.single()
	match found {
		Ok(clock) => {
			wave = 0.5 + 0.5 * F32.sin(Clock.get(clock).total * 1.6)
			world.map_with(|_radius, Pulse.(p)| Radius.(p.base + p.amount * wave))
		}
		Err(_) => world
	}
}

# Components

## Marks an entity whose `Position` tracks the pointer.
Follower := {}.{
	to_col : List(Follower) -> [Followers(List(Follower))]
	to_col = |list| Followers(list)

	from_col = |col| match col {
		Followers(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## Marks an entity drawn in the accent color, at this alpha.
Accent := U8.{
	to_col : List(Accent) -> [Accents(List(Accent))]
	to_col = |list| Accents(list)

	from_col = |col| match col {
		Accents(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## Makes an entity's `Radius` swing between `base` and `base + amount`.
Pulse := { base : F32, amount : F32 }.{
	to_col : List(Pulse) -> [Pulses(List(Pulse))]
	to_col = |list| Pulses(list)

	from_col = |col| match col {
		Pulses(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

# Tests

## What `RayEcs` would draw for a world, back to front.
drawn = |world| RayEcs.scene(world).map(
	|command| match command {
		GradientV(_) => "gradient"
		GradientH(_) => "gradient"
		CircleGradient(_) => "glow"
		Rectangle(_) => "rectangle"
		RoundedRectangle(_) => "rounded"
		Circle(_) => "circle"
		Text(_) => "text"
		Fps(_) => "fps"
	},
)

expect drawn(scene(Text.font_stub)) == ["gradient", "glow", "glow", "fps", "rounded", "rounded", "rectangle", "text", "text", "circle", "circle", "circle"]

# Holding the left button turns every accent red, at the alpha it asked for.
expect {
	held = App.Input.for_tests({}).with_devices(Devices.none.with_mouse_position({ x: 30, y: 40 }).with_mouse_button_down(Left))
	world = tint_accents(follow_pointer(RayEcs.write_devices(RayEcs.spawn_devices(scene(Text.font_stub)), held)))
	fills = world.select().having(Accent.to_col).query1().map(|(_, fill)| FillColor.get(fill))
	followers = world.select().having(Follower.to_col).query1().map(|(_, position)| Position.get(position))
	fills == [Color.with_alpha(red, 170), Color.with_alpha(red, 40), Color.with_alpha(red, 255)]
		and followers == [{ x: 30, y: 40 }, { x: 30, y: 40 }, { x: 30, y: 40 }]
}
