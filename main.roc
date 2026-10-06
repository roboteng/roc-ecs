app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0/5xecDmRJroKT9fnSiYsGdCKEzNWLnRKGtHJ5CxuCnpb9.tar.zst" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Text
import rr.Font
import rr.Math

## State kept between updates: prepared text and layout that can be reused,
## plus the latest pointer position, button state, and elapsed time needed to
## draw the next frame.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,
	layout : Layout,
	pointer : { x : F32, y : F32 },
	accent_on : Bool,

	## Seconds since launch, folded in from `input.time`. `render!` gets no
	## input, so anything that moves has to be read off the model like this.
	elapsed : F32,
	world : MyWorld,
}

Layout : {
	panel : { x : F32, y : F32, width : F32, height : F32 },
	title_size : Draw.TextSize,
}

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("Hello RocRay")
		.with_size({ width: 800, height: 600 })
		.with_frame_pacing(Capped(120)),

	|_io| {
		font = Draw.default_font!()
		Ok({
			title: Text.from("Roc :heart: Raylib", font).size(38).prepare!()?,
			help: Text.from("Move the pointer  -  click for an accent  -  ESC exits", font).size(18).prepare!()?,
			layout: solve_layout(font),
			pointer: { x: 400, y: 300 },
			accent_on: Bool.False,
			elapsed: 0,
			world: new_world(),
		})
	},
)

## Nothing here waits, so there is no task to spawn and no message to fold in.
## An app that reads a file or fetches a URL gives `Msg` the variants those
## tasks answer with; see the `task_sleep` and `async_read` examples.
Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, program_input, _io| {
	input = program_input.devices
	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({
			..model,
			pointer: input.mouse.position(),
			accent_on: input.mouse.button_down(Left),
			elapsed: model.elapsed + program_input.time.elapsed_seconds,
		})
	}
}

solve_layout : Text.Font -> Layout
solve_layout = |font| {
	panel: { x: 120, y: 150, width: 560, height: 300 },
	title_size: font.measure({ text: "Roc :heart: Raylib", size: 38, spacing: Text.default_spacing }),
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	accent = if model.accent_on Color.from_hex_rgb(0xf94144) else Color.from_hex_rgb(0x2f80ed)
	panel = model.layout.panel
	title_size = model.layout.title_size
	# One slow sine drives every moving part, so the scene breathes together.
	pulse = 0.5 + 0.5 * F32.sin(model.elapsed * 1.6)

	frame.rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: Color.from_hex_rgb(0x131f38), color_bottom: Color.from_hex_rgb(0x070b16) })
	frame.circle_gradient!({ center: { x: 620, y: 90 }, radius: 220 + 40 * pulse, color_inner: Color.with_alpha(accent, 90), color_outer: Color.with_alpha(accent, 0) })
	frame.circle_gradient!({ center: { x: 150, y: 540 }, radius: 260, color_inner: Color.with_alpha(Color.from_hex_rgb(0x06d6a0), 45), color_outer: Color.with_alpha(Color.from_hex_rgb(0x06d6a0), 0) })
	frame.fps!({ color: Color.white, pos: { x: 0, y: 0 }, size: 32 })

	# A soft drop shadow, then the panel itself over the top of it.
	frame.rounded_rectangle!({ x: panel.x + 6, y: panel.y + 10, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled(Color.with_alpha(Color.black, 90)) })
	frame.rounded_rectangle!({ x: panel.x, y: panel.y, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x18243b), Color.with_alpha(Color.white, 55), 2) })

	model.title.draw!(frame, { pos: { x: 400, y: 230 }, color: Color.white, align: (Top, Center) })
	frame.line!({ start: { x: 400 - title_size.width * 0.5, y: 288 }, end: { x: 400 + title_size.width * 0.5, y: 288 }, stroke: Draw.stroke(Color.with_alpha(accent, 170), 3) })
	model.help.draw!(frame, { pos: { x: 400, y: 310 }, color: Color.from_hex_rgb(0xa8b4cc), align: (Top, Center) })

	# The pointer gets a halo that pulses with the same clock as the backdrop.
	frame.circle!({ center: model.pointer, radius: 26 + 8 * pulse, style: Draw.filled(Color.with_alpha(accent, 40)) })
	frame.circle!({ center: model.pointer, radius: 18, style: Draw.filled_and_outlined(accent, Color.white, 3) })

	Ok({})
}

World(s) := {
	entities : Store({}),
	unused : List(Entity),
	inputs : List((World(s), App.Input(Msg) => Try(World(s), []))),
	updates : List(World(s) -> World(s)),
	renders : List((World(s), Draw.Frame => Try({}, [Exit(I64)]))),
	components : s,
}.{
	empty : s -> World(s)
	empty = |components| World.(
		{
			entities: Store.empty(),
			components: components,
			unused: [],
			inputs: [],
			updates: [],
			renders: [],
		},
	)

	input! : World, App.Input(Msg) => Try(World, [])
	input! = |w, io| {
		var $world = w
		for input in w.inputs {
			$world = input($world, io)?
		}
		Ok($world)
	}

	update : World -> World
	update = |w| w.updates.fold(w, |world, system| system(world))

	render! : World, Draw.Frame => Try({}, [Exit(I64)])
	render! = |w, frame| {
		for r in w.renders {
			r(w, frame)?
		}
		Ok({})
	}

	spawn_empty : World -> (World, Entity)
	spawn_empty = |world| {
		len = world.unused.len()
		match world.unused.last() {
			Err(ListWasEmpty) => {
				Store.(entities) = world.entities
				ent = entities.len()
				entity = Entity.(EntityId.(ent.to_u32_wrap()), GenerationId.(0))
				World.(w) = world
				(
					World.(
						{
							..w,
							entities: world.entities.insert(entity, {}),
						},
					),
					entity,
				)
			}
			Ok(ent) => {
				unused = world.unused.take_first(len - 1)
				n_ent = ent.inc_gen()
				World.(w) = world
				(
					World.(
						{
							..w,
							unused: unused,

						},
					),
					n_ent,
				)
			}
		}
	}
}

Storage := {
	time : Store(F32),
	text : Store(Text.Prepared),
	pointer : Store({}),
	position : Store(Math.Vec2),
	size : Store(Math.Vec2),
	radius : Store(F32),
	fill_color : Store(Color),
}

MyWorld : World(Storage)

new_world = || World.empty(
	Storage.(
		{
			time: Store.empty(),
			text: Store.empty(),
			pointer: Store.empty(),
			position: Store.empty(),
			size: Store.empty(),
			radius: Store.empty(),
			fill_color: Store.empty(),
		},
	),
)

Store(a) := Dict(EntityId, (GenerationId, a)).{
	empty = || Store.(Dict.empty())

	insert : Store, Entity, a -> Store
	insert = |Store.(store), Entity.(ent, gen), comp| Store.(store.insert(ent, (gen, comp)))

	get : Store, Entity -> Try(a, _)
	get = |Store.(store), Entity.(ent, gen)| {
		(stored_gen, stored_comp) = store.get(ent) ? |_| EntityNotFound
		if gen == stored_gen {
			Ok(stored_comp)
		} else {
			Err(EntityExpired)
		}
	}
}

EntityId := U32.{
	is_eq : _
	to_hash : _
}

GenerationId := U32.{
	is_eq : _
}

Entity := (EntityId, GenerationId).{
	inc_gen = |Entity.(ent, GenerationId.(gen))| Entity.(ent, GenerationId.(gen + 1))
}

Center := Math.Vec2.{
	comp = || Center
}

Components := [Center, Unused]
