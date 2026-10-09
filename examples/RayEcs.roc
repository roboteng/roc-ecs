package
	[]
	{
		ecs: "../package/main.roc",
		rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0/5xecDmRJroKT9fnSiYsGdCKEzNWLnRKGtHJ5CxuCnpb9.tar.zst",
	}

import rr.App
import rr.Color
import rr.Devices
import rr.Draw
import rr.Keys
import rr.Mouse
import rr.Text
import ecs.Ecs exposing [World]

## Runs an `IOWorld` on RocRay: its input is the `App.Input` that
## `update!` receives, and its output is the `Draw.Frame` that `render!` draws
## through.
##
## `RayEcs.default` gives a world that already reads the devices and draws
## every entity that has the components of a shape:
##
## ```roc
## world = RayEcs.default(
##     Ecs.World.empty()
##         .spawn4(Position.({ x: 20, y: 20 }), Size.({ width: 200, height: 80 }), FillColor.(Color.blue), BorderColor.(Color.white))
##         .add_system(move),
## )
##
## update! = |model, input, _io| Ok({ ..model, world: RayEcs.update!(model.world, input)? })
##
## render! = |model, frame| RayEcs.render!(model.world, frame)
## ```
##
## A `RayEcs.World` is a `RayEcs.IOWorld`, so more systems are added with its
## `add_input` and `add_output`.
##
## What gets drawn. A `Layer` decides the order, lowest first; within a layer
## it is the order of this table:
##
## | Components | Shape |
## | --- | --- |
## | `Position`, `Size`, `Gradient` | gradient rectangle |
## | `Position`, `Radius`, `RadialGradient` | gradient circle |
## | `Position`, `Size`, `FillColor`, `BorderColor`, no `CornerRadius` | rectangle |
## | `Position`, `Size`, `FillColor`, `BorderColor`, `CornerRadius` | rounded rectangle |
## | `Position`, `Radius`, `FillColor`, optionally `BorderColor` | circle |
## | `Position`, `Label`, `TextColor`, optionally `TextAlign` | text |
## | `Position`, `FpsCounter`, `TextColor` | frame rate |
RayEcs :: [].{

	## A world that talks to the outside.
	##
	## col -> tag union of the component columns
	## i -> input type, how the world gets information from the outside
	## o -> output type, how the world sends information to the outside
	## e -> error type
	IOWorld(col, i, o, e) := {
		inner : World(col),
		input_systems : List((IOWorld(col, i, o, e), i => Try(IOWorld(col, i, o, e), e))),
		output_systems : List((IOWorld(col, i, o, e), o => Try({}, e))),
	}.{
		new : World(col) -> IOWorld(col, i, o, e)
		new = |world| IOWorld.({ inner: world, input_systems: [], output_systems: [] })

		add_input : IOWorld(col, i, o, e), (IOWorld(col, i, o, e), i => Try(IOWorld(col, i, o, e), e)) -> IOWorld(col, i, o, e)
		add_input = |io_world, system| IOWorld.(
			{
				inner: io_world.inner,
				input_systems: io_world.input_systems.append(system),
				output_systems: io_world.output_systems,
			},
		)

		add_output : IOWorld(col, i, o, e), (IOWorld(col, i, o, e), o => Try({}, e)) -> IOWorld(col, i, o, e)
		add_output = |io_world, system| IOWorld.(
			{
				inner: io_world.inner,
				input_systems: io_world.input_systems,
				output_systems: io_world.output_systems.append(system),
			},
		)

		## Feeds `input` through every input system, in the order they were
		## added.
		input! : IOWorld(col, i, o, e), i => Try(IOWorld(col, i, o, e), e)
		input! = |io_world, input| {
			var $world = io_world
			for system in io_world.input_systems {
				$world = system($world, input)?
			}
			Ok($world)
		}

		## Runs the inner world's systems once.
		update : IOWorld(col, i, o, e) -> IOWorld(col, i, o, e)
		update = |io_world| IOWorld.(
			{
				inner: io_world.inner.update(),
				input_systems: io_world.input_systems,
				output_systems: io_world.output_systems,
			},
		)

		## Runs every output system, in the order they were added.
		output! : IOWorld(col, i, o, e), o => Try({}, e)
		output! = |io_world, out| {
			for system in io_world.output_systems {
				system(io_world, out)?
			}
			Ok({})
		}
	}

	## col -> tag union of the component columns
	## msg -> the app's task message type
	## e -> errors a system can stop the app with, on top of `Exit`
	World(col, msg, e) : IOWorld(col, App.Input(msg), Draw.Frame, [Exit(I64), ..e])

	## Reads the host's input for this cycle. Runs in `update!`, before the
	## world's own systems.
	InputSystem(col, msg, e) : World(col, msg, e), App.Input(msg) => Try(World(col, msg, e), [Exit(I64), ..e])

	## Draws the world. Runs in `render!`, the only place drawing is legal.
	DrawSystem(col, msg, e) : World(col, msg, e), Draw.Frame => Try({}, [Exit(I64), ..e])

	## A world with no input or output systems of its own.
	new : Ecs.World(col) -> World(col, msg, e)
	new = |world| IOWorld.new(world)

	## A world with a devices entity, kept current by `read_devices`, that
	## draws its shapes with `draw!`.
	default = |world| RayEcs.new(RayEcs.spawn_devices(world)).add_input(RayEcs.read_devices).add_output(RayEcs.draw!)

	## One `update!` cycle: every input system, then every system of the
	## inner world.
	update! : World(col, msg, e), App.Input(msg) => Try(World(col, msg, e), [Exit(I64), ..e])
	update! = |world, input| Ok(world.input!(input)?.update())

	## One `render!`: every output system, in the order they were added.
	render! : World(col, msg, e), Draw.Frame => Try({}, [Exit(I64), ..e])
	render! = |world, frame| world.output!(frame)

	# Input

	## Spawns the entity that holds the `Pointer`, the `Keyboard` and the
	## `Clock`. Systems read them with `single`:
	##
	##     pointer : RayEcs.Pointer
	##     pointer = world.single()?
	spawn_devices = |world| world.spawn3(Pointer.(Devices.none.mouse), Keyboard.(Devices.none), Clock.({ dt: 0, total: 0 }))

	## The input system that keeps every `Pointer`, `Keyboard` and `Clock`
	## current.
	read_devices = |world, input| Ok(IOWorld.({ ..world, inner: RayEcs.write_devices(world.inner, input) }))

	## `read_devices` without the `IOWorld` around it.
	write_devices = |world, input| {
		dt = input.time.elapsed_seconds
		world
			.map1(|Pointer.(_)| Pointer.(input.devices.mouse))
			.map1(|Keyboard.(_)| Keyboard.(input.devices))
			.map1(|Clock.(clock)| Clock.({ dt: dt, total: clock.total + dt }))
	}

	# Drawing

	## The output system that draws every shape: lowest `Layer` first, and
	## within a layer in the order of the table at the top of this module.
	draw! = |world, frame| {
		for command in RayEcs.scene(world.inner) {
			match command {
				GradientV(rect) => frame.rectangle_gradient_v!(rect)
				GradientH(rect) => frame.rectangle_gradient_h!(rect)
				CircleGradient(circle) => frame.circle_gradient!(circle)
				Rectangle(rect) => frame.rectangle!(rect)
				RoundedRectangle(rect) => frame.rounded_rectangle!(rect)
				Circle(circle) => frame.circle!(circle)
				Text(text) => Text.from(text.text, text.font).size(text.size).draw!(frame, { pos: text.pos, color: text.color, align: text.align })
				Fps(fps) => frame.fps!(fps)
			}
		}
		Ok({})
	}

	## Every draw call for a world, as data and in the order `draw!` makes
	## them, so what a world would draw can be checked in an `expect`.
	scene = |world| {
		commands = RayEcs.gradients(world)
			.concat(RayEcs.circle_gradients(world))
			.concat(RayEcs.rectangles(world))
			.concat(RayEcs.rounded_rectangles(world))
			.concat(RayEcs.circles(world))
			.concat(RayEcs.labels(world))
			.concat(RayEcs.fps_counters(world))
		layers = commands.fold([], |seen, (layer, _)| if seen.contains(layer) seen else seen.append(layer)).sort_by(|layer| layer)
		layers.fold(
			[],
			|drawn, layer| commands.fold(drawn, |acc, (at, command)| if at == layer acc.append(command) else acc),
		)
	}

	## The draw calls for one kind of shape, each with its entity's layer.
	gradients = |world| world.query3().map(
		|(entity, Position.(p), Size.(s), Gradient.(gradient))| (
			RayEcs.layer_of(world, entity),
			match gradient {
				TopToBottom(top, bottom) => GradientV({ x: p.x, y: p.y, width: s.width, height: s.height, color_top: top, color_bottom: bottom })
				LeftToRight(left, right) => GradientH({ x: p.x, y: p.y, width: s.width, height: s.height, color_left: left, color_right: right })
			},
		),
	)

	circle_gradients = |world| world.query3().map(
		|(entity, Position.(p), Radius.(radius), RadialGradient.(gradient))| (
			RayEcs.layer_of(world, entity),
			CircleGradient({ center: { x: p.x, y: p.y }, radius: radius, color_inner: gradient.inner, color_outer: gradient.outer }),
		),
	)

	rectangles = |world| world.select().without(CornerRadius.to_col).query4().map(
		|(entity, Position.(p), Size.(s), FillColor.(fill), BorderColor.(border))| (
			RayEcs.layer_of(world, entity),
			Rectangle({
				x: p.x,
				y: p.y,
				width: s.width,
				height: s.height,
				style: Draw.filled_and_outlined(fill, border, RayEcs.border_width(world, entity)),
			}),
		),
	)

	rounded_rectangles = |world| world.query5().map(
		|(entity, Position.(p), Size.(s), FillColor.(fill), BorderColor.(border), CornerRadius.(radius))| (
			RayEcs.layer_of(world, entity),
			RoundedRectangle({
				x: p.x,
				y: p.y,
				width: s.width,
				height: s.height,
				radius: radius,
				segments: 12,
				style: Draw.filled_and_outlined(fill, border, RayEcs.border_width(world, entity)),
			}),
		),
	)

	circles = |world| {
		plain = world.select().without(BorderColor.to_col).query3().map(
			|(entity, Position.(p), Radius.(radius), FillColor.(fill))| (
				RayEcs.layer_of(world, entity),
				Circle({ center: { x: p.x, y: p.y }, radius: radius, style: Draw.filled(fill) }),
			),
		)
		bordered = world.query4().map(
			|(entity, Position.(p), Radius.(radius), FillColor.(fill), BorderColor.(border))| (
				RayEcs.layer_of(world, entity),
				Circle({
					center: { x: p.x, y: p.y },
					radius: radius,
					style: Draw.filled_and_outlined(fill, border, RayEcs.border_width(world, entity)),
				}),
			),
		)
		plain.concat(bordered)
	}

	labels = |world| world.query3().map(
		|(entity, Position.(p), Label.(label), TextColor.(color))| (
			RayEcs.layer_of(world, entity),
			Text({
				pos: { x: p.x, y: p.y },
				text: label.text,
				size: label.size,
				font: label.font,
				color: color,
				align: match world.get(entity) {
					Ok(TextAlign.(align)) => align
					Err(_) => (Top, Left)
				},
			}),
		),
	)

	fps_counters = |world| world.query3().map(
		|(entity, Position.(p), FpsCounter.(size), TextColor.(color))| (
			RayEcs.layer_of(world, entity),
			Fps({ pos: { x: p.x, y: p.y }, size: size, color: color }),
		),
	)

	layer_of = |world, entity| match world.get(entity) {
		Ok(Layer.(layer)) => layer
		Err(_) => 0
	}

	border_width = |world, entity| match world.get(entity) {
		Ok(BorderWidth.(width)) => width
		Err(_) => 1
	}

	# Components
	#
	# A nominal type can only be taken apart with `Name.(inner)` in the module
	# that defines it, so each component has a `get` for everywhere else:
	# `Radius.get(radius)`, or `radius.get()` once its type is known.

	## The mouse as of the latest `update!`. Kept current by `read_devices` on
	## every entity that has one; `spawn_devices` makes the usual single one.
	Pointer := Mouse.Snapshot.{
		get : Pointer -> Mouse.Snapshot
		get = |Pointer.(inner)| inner

		to_col : List(Pointer) -> [Pointers(List(Pointer))]
		to_col = |list| Pointers(list)

		from_col = |col| match col {
			Pointers(list) => Ok(list)
			_ => Err(WrongColumn)
		}

		position : Pointer -> { x : F32, y : F32 }
		position = |Pointer.(mouse)| mouse.position()

		## Movement since the previous cycle.
		delta : Pointer -> { x : F32, y : F32 }
		delta = |Pointer.(mouse)| mouse.delta()

		wheel : Pointer -> { x : F32, y : F32 }
		wheel = |Pointer.(mouse)| mouse.wheel_delta()

		## Held right now.
		down : Pointer, Mouse.Button -> Bool
		down = |Pointer.(mouse), button| mouse.button_down(button)

		## Went down this cycle.
		pressed : Pointer, Mouse.Button -> Bool
		pressed = |Pointer.(mouse), button| mouse.button_pressed(button)

		## Went up this cycle.
		released : Pointer, Mouse.Button -> Bool
		released = |Pointer.(mouse), button| mouse.button_released(button)
	}

	## The keys as of the latest `update!`. Kept current by `read_devices`.
	Keyboard := Devices.Snapshot.{
		get : Keyboard -> Devices.Snapshot
		get = |Keyboard.(inner)| inner

		to_col : List(Keyboard) -> [Keyboards(List(Keyboard))]
		to_col = |list| Keyboards(list)

		from_col = |col| match col {
			Keyboards(list) => Ok(list)
			_ => Err(WrongColumn)
		}

		## Held right now.
		down : Keyboard, Keys.Key -> Bool
		down = |Keyboard.(devices), key| devices.key_down(key)

		## Went down this cycle.
		pressed : Keyboard, Keys.Key -> Bool
		pressed = |Keyboard.(devices), key| devices.key_pressed(key)

		## Went up this cycle.
		released : Keyboard, Keys.Key -> Bool
		released = |Keyboard.(devices), key| devices.key_released(key)
	}

	## Seconds since the previous cycle, and since the clock was spawned. Kept
	## current by `read_devices`.
	Clock := { dt : F32, total : F32 }.{
		get : Clock -> { dt : F32, total : F32 }
		get = |Clock.(inner)| inner

		to_col : List(Clock) -> [Clocks(List(Clock))]
		to_col = |list| Clocks(list)

		from_col = |col| match col {
			Clocks(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## Optional: when an entity is drawn. Lower layers are drawn first, so
	## higher ones end up on top. An entity without one is on layer 0.
	Layer := I32.{
		get : Layer -> I32
		get = |Layer.(inner)| inner

		to_col : List(Layer) -> [Layers(List(Layer))]
		to_col = |list| Layers(list)

		from_col = |col| match col {
			Layers(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## With a `Position` and a `Radius`, draws a circle that fades from its
	## center to its edge.
	RadialGradient := { inner : Color.Rgba, outer : Color.Rgba }.{
		get : RadialGradient -> { inner : Color.Rgba, outer : Color.Rgba }
		get = |RadialGradient.(inner)| inner

		to_col : List(RadialGradient) -> [RadialGradients(List(RadialGradient))]
		to_col = |list| RadialGradients(list)

		from_col = |col| match col {
			RadialGradients(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## Optional: which point of a `Label` its `Position` names. Without one it
	## is the top left corner.
	TextAlign := (Text.VAlign, Text.HAlign).{
		get : TextAlign -> (Text.VAlign, Text.HAlign)
		get = |TextAlign.(inner)| inner

		to_col : List(TextAlign) -> [TextAligns(List(TextAlign))]
		to_col = |list| TextAligns(list)

		from_col = |col| match col {
			TextAligns(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## With a `Position` and a `TextColor`, draws the frame rate at this text
	## size.
	FpsCounter := F32.{
		get : FpsCounter -> F32
		get = |FpsCounter.(inner)| inner

		to_col : List(FpsCounter) -> [FpsCounters(List(FpsCounter))]
		to_col = |list| FpsCounters(list)

		from_col = |col| match col {
			FpsCounters(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## Where an entity is drawn: the top left corner of anything with a `Size`,
	## the center of anything with a `Radius`, and for a `Label` the point its
	## `TextAlign` names.
	Position := { x : F32, y : F32 }.{
		get : Position -> { x : F32, y : F32 }
		get = |Position.(inner)| inner

		to_col : List(Position) -> [Positions(List(Position))]
		to_col = |list| Positions(list)

		from_col = |col| match col {
			Positions(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	Size := { width : F32, height : F32 }.{
		get : Size -> { width : F32, height : F32 }
		get = |Size.(inner)| inner

		to_col : List(Size) -> [Sizes(List(Size))]
		to_col = |list| Sizes(list)

		from_col = |col| match col {
			Sizes(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## With a `Position` and a `FillColor`, draws a circle.
	Radius := F32.{
		get : Radius -> F32
		get = |Radius.(inner)| inner

		to_col : List(Radius) -> [Radii(List(Radius))]
		to_col = |list| Radii(list)

		from_col = |col| match col {
			Radii(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## Turns a rectangle into a rounded one.
	CornerRadius := F32.{
		get : CornerRadius -> F32
		get = |CornerRadius.(inner)| inner

		to_col : List(CornerRadius) -> [CornerRadii(List(CornerRadius))]
		to_col = |list| CornerRadii(list)

		from_col = |col| match col {
			CornerRadii(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	FillColor := Color.Rgba.{
		get : FillColor -> Color.Rgba
		get = |FillColor.(inner)| inner

		to_col : List(FillColor) -> [FillColors(List(FillColor))]
		to_col = |list| FillColors(list)

		from_col = |col| match col {
			FillColors(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	BorderColor := Color.Rgba.{
		get : BorderColor -> Color.Rgba
		get = |BorderColor.(inner)| inner

		to_col : List(BorderColor) -> [BorderColors(List(BorderColor))]
		to_col = |list| BorderColors(list)

		from_col = |col| match col {
			BorderColors(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## Optional: a border without one is 1 thick.
	BorderWidth := F32.{
		get : BorderWidth -> F32
		get = |BorderWidth.(inner)| inner

		to_col : List(BorderWidth) -> [BorderWidths(List(BorderWidth))]
		to_col = |list| BorderWidths(list)

		from_col = |col| match col {
			BorderWidths(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## With a `Position` and a `Size`, draws a gradient rectangle.
	Gradient := [TopToBottom(Color.Rgba, Color.Rgba), LeftToRight(Color.Rgba, Color.Rgba)].{
		get : Gradient -> [TopToBottom(Color.Rgba, Color.Rgba), LeftToRight(Color.Rgba, Color.Rgba)]
		get = |Gradient.(inner)| inner

		to_col : List(Gradient) -> [Gradients(List(Gradient))]
		to_col = |list| Gradients(list)

		from_col = |col| match col {
			Gradients(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	## With a `Position` and a `TextColor`, draws text. `Draw.default_font!()`
	## gives a font to start with.
	Label := { text : Str, size : F32, font : Text.Font }.{
		get : Label -> { text : Str, size : F32, font : Text.Font }
		get = |Label.(inner)| inner

		to_col : List(Label) -> [Labels(List(Label))]
		to_col = |list| Labels(list)

		from_col = |col| match col {
			Labels(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}

	TextColor := Color.Rgba.{
		get : TextColor -> Color.Rgba
		get = |TextColor.(inner)| inner

		to_col : List(TextColor) -> [TextColors(List(TextColor))]
		to_col = |list| TextColors(list)

		from_col = |col| match col {
			TextColors(list) => Ok(list)
			_ => Err(WrongColumn)
		}
	}
}

# Tests

at = |x, y| RayEcs.Position.({ x: x, y: y })

sized = |width, height| RayEcs.Size.({ width: width, height: height })

fill = RayEcs.FillColor.(Color.blue)

border = RayEcs.BorderColor.(Color.white)

## Two boxes, a rounded box, and a box with no border.
boxes = || Ecs.World.empty()
	.spawn4(at(1, 1), sized(10, 10), fill, border)
	.spawn(Ecs.Bundle.empty().add(at(2, 2)).add(sized(20, 20)).add(fill).add(border).add(RayEcs.BorderWidth.(3))).0
	.spawn(Ecs.Bundle.empty().add(at(3, 3)).add(sized(30, 30)).add(fill).add(border).add(RayEcs.CornerRadius.(8))).0
	.spawn3(at(4, 4), sized(40, 40), fill)

# A rectangle needs all four components and no corner radius. Its border is 1
# thick unless it has a `BorderWidth`.
expect RayEcs.rectangles(boxes()) == [
	(0, Rectangle({ x: 1, y: 1, width: 10, height: 10, style: Draw.filled_and_outlined(Color.blue, Color.white, 1) })),
	(0, Rectangle({ x: 2, y: 2, width: 20, height: 20, style: Draw.filled_and_outlined(Color.blue, Color.white, 3) })),
]

expect RayEcs.rounded_rectangles(boxes()) == [
	(0, RoundedRectangle({ x: 3, y: 3, width: 30, height: 30, radius: 8, segments: 12, style: Draw.filled_and_outlined(Color.blue, Color.white, 1) })),
]

expect {
	world = Ecs.World.empty()
		.spawn3(at(1, 1), RayEcs.Radius.(5), fill)
		.spawn4(at(2, 2), RayEcs.Radius.(6), fill, border)
		.spawn2(at(3, 3), RayEcs.Radius.(7))
	RayEcs.circles(world) == [
		(0, Circle({ center: { x: 1, y: 1 }, radius: 5, style: Draw.filled(Color.blue) })),
		(0, Circle({ center: { x: 2, y: 2 }, radius: 6, style: Draw.filled_and_outlined(Color.blue, Color.white, 1) })),
	]
}

expect {
	world = Ecs.World.empty()
		.spawn3(at(1, 1), sized(10, 20), RayEcs.Gradient.(TopToBottom(Color.red, Color.blue)))
		.spawn3(at(2, 2), sized(30, 40), RayEcs.Gradient.(LeftToRight(Color.red, Color.blue)))
		.spawn3(at(3, 3), RayEcs.Radius.(9), RayEcs.RadialGradient.({ inner: Color.red, outer: Color.blue }))
	RayEcs.gradients(world) == [
		(0, GradientV({ x: 1, y: 1, width: 10, height: 20, color_top: Color.red, color_bottom: Color.blue })),
		(0, GradientH({ x: 2, y: 2, width: 30, height: 40, color_left: Color.red, color_right: Color.blue })),
	]
		and RayEcs.circle_gradients(world) == [(0, CircleGradient({ center: { x: 3, y: 3 }, radius: 9, color_inner: Color.red, color_outer: Color.blue }))]
}

# A label is anchored at its top left corner unless it has a `TextAlign`.
expect {
	label = |text| RayEcs.Label.({ text: text, size: 20, font: Text.font_stub })
	world = Ecs.World.empty()
		.spawn3(at(1, 1), label("hi"), RayEcs.TextColor.(Color.white))
		.spawn4(at(2, 2), label("centered"), RayEcs.TextColor.(Color.white), RayEcs.TextAlign.((Middle, Center)))
		.spawn2(at(3, 3), label("no color"))
	RayEcs.labels(world).map(
		|(_, command)| match command {
			Text(text) => (text.text, text.pos.x, text.align)
		},
	)
		== [("hi", 1, (Top, Left)), ("centered", 2, (Middle, Center))]
}

expect {
	world = Ecs.World.empty().spawn3(at(1, 1), RayEcs.FpsCounter.(32), RayEcs.TextColor.(Color.white))
	RayEcs.fps_counters(world) == [(0, Fps({ pos: { x: 1, y: 1 }, size: 32, color: Color.white }))]
}

# Layers decide the order across kinds of shape; within a layer a rectangle is
# drawn before a circle, whichever was spawned first.
expect {
	world = Ecs.World.empty()
		.spawn4(at(1, 1), RayEcs.Radius.(1), fill, RayEcs.Layer.(1))
		.spawn3(at(2, 2), RayEcs.Radius.(2), fill)
		.spawn(Ecs.Bundle.empty().add(at(3, 3)).add(sized(3, 3)).add(fill).add(border).add(RayEcs.Layer.(2))).0
		.spawn4(at(4, 4), sized(4, 4), fill, border)
		.spawn(Ecs.Bundle.empty().add(at(5, 5)).add(sized(5, 5)).add(fill).add(border).add(RayEcs.Layer.(-1))).0
	RayEcs.scene(world).map(
		|command| match command {
			Rectangle(rect) => rect.x
			Circle(circle) => circle.center.x
			_ => 0
		},
	)
		== [5, 4, 2, 1, 3]
}

expect {
	input : App.Input([])
	input = App.Input.for_tests({})
		.with_devices(Devices.none.with_mouse_position({ x: 30, y: 40 }).with_mouse_button_pressed(Left).with_key_down(KeySpace))
		.with_time({ cycle_count: 1, simulation_nanos: 0, monotonic_nanos: 0, elapsed_seconds: 0.5 })
	world = RayEcs.write_devices(RayEcs.write_devices(RayEcs.spawn_devices(Ecs.World.empty()), input), input)
	pointer : RayEcs.Pointer
	pointer = world.single()?
	keyboard : RayEcs.Keyboard
	keyboard = world.single()?
	RayEcs.Clock.(clock) = world.single()?
	pointer.position() == { x: 30, y: 40 }
		and pointer.pressed(Left) and !pointer.down(Right)
			and keyboard.down(KeySpace) and !keyboard.down(KeyEnter)
				and clock.dt == 0.5 and clock.total == 1
}
