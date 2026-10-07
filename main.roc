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
Model(s) : {
	title : Text.Prepared,
	help : Text.Prepared,
	layout : Layout,
	pointer : { x : F32, y : F32 },
	accent_on : Bool,

	## Seconds since launch, folded in from `input.time`. `render!` gets no
	## input, so anything that moves has to be read off the model like this.
	elapsed : F32,
	world : World(s),
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
			world: {
				world1 = World.empty({
					time: Store.empty(),
					pos: Store.empty(),
					pointer: Store.empty(),
				}).add_input(write_time).add_input(write_pointer)
				(world2, _) = world1.spawn(
					Time.(
						{
							dt: 0,
							total: 0,
						},
					),
				)
				(world3, _) = world2.spawn2(Pos.({ x: 0, y: 0 }), Pointer.({}))
				world3
			},
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
			world: model.world.input!(program_input)?,
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

write_time : (World(s), App.Input(Msg) => Try(World(s), []))
write_time = |w, io| {
	dt = io.time.elapsed_seconds
	Ok(w.map_comp(|Time.(v)| Time.({ total: v.total + dt, dt: dt })))
}

write_pointer : (World(s), App.Input(Msg) => Try(World(s), []))
write_pointer = |w, input| {
	mouse = input.devices.mouse
	Ok(
		w.map_comp2(
			|Pos.(_), Pointer.(_)| (
				Pos.({ x: mouse.x, y: mouse.y }),
				Pointer.({}),
			),
		),
	)
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

	add_input = |World.(world), system| World.({ ..world, inputs: world.inputs.append(system) })
	add_system = |World.(world), system| World.({ ..world, updates: world.updates.append(system) })
	add_render = |World.(world), system| World.({ ..world, renders: world.renders.append(system) })

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

	spawn : World(s), c -> (World(s), Entity)
		where [
			c.from_world : s -> Store(c),
			c.to_world : s, Store(c) -> s,
		]
	spawn = |world, component| {
		(World.(world1), entity) = world.spawn_empty()
		C : c
		store = C.from_world(world.components).insert(entity, component)
		(World.({ ..world1, components: C.to_world(world1.components, store) }), entity)
	}

	spawn2 : World(s), c1, c2 -> (World(s), Entity)
		where [
			c1.from_world : s -> Store(c1),
			c1.to_world : s, Store(c1) -> s,
			c2.from_world : s -> Store(c2),
			c2.to_world : s, Store(c2) -> s,
		]
	spawn2 = |world, component1, component2| {
		(World.(world1), entity) = world.spawn_empty()
		C1 : c1
		C2 : c2
		store1 = C1.from_world(world.components).insert(entity, component1)
		store2 = C2.from_world(world.components).insert(entity, component2)
		(
			World.(
				{
					..world1,
					components: C2.to_world(C1.to_world(world1.components, store1), store2),
				},
			),
			entity,
		)
	}

	map_store : World, (Store(c) -> Store(c)) -> World
		where [
			c.from_world : s -> Store(c),
			c.to_world : s, Store(c) -> s,
		]
	map_store = |World.(world), map| {
		C : c
		World.(
			{
				..world,
				components: C.to_world(world.components, map(C.from_world(world.components))),
			},
		)
	}

	map_comp : World, (c -> c) -> World
		where [
			c.from_world : s -> Store(c),
			c.to_world : s, Store(c) -> s,
		]
	map_comp = |World.(world), fn| {
		C : c
		World.(
			{
				..world,
				components: C.to_world(world.components, C.from_world(world.components).map(fn)),
			},
		)
	}

	map_comp2 : World, (c, d -> (c, d)) -> World
		where [
			c.from_world : s -> Store(c),
			c.to_world : s, Store(c) -> s,
			d.from_world : s -> Store(d),
			d.to_world : s, Store(d) -> s,
		]
	map_comp2 = |World.(world), fn| {
		C : c
		D : d
		Store.(store_c) = C.from_world(world.components)
		Store.(store_d) = D.from_world(world.components)
		(new_c, new_d) = store_d.fold(
			(store_c, store_d),
			|(acc_c, acc_d), ent, (gen_d, comp_d)| match store_c.get(ent) {
				Ok((gen_c, comp_c)) if gen_c == gen_d => {
					(out_c, out_d) = fn(comp_c, comp_d)
					(acc_c.insert(ent, (gen_c, out_c)), acc_d.insert(ent, (gen_d, out_d)))
				}
				_ => (acc_c, acc_d)
			},
		)
		World.(
			{
				..world,
				components: C.to_world(D.to_world(world.components, Store.(new_d)), Store.(new_c)),
			},
		)
	}
}

Store(a) := Dict(EntityId, (GenerationId, a)).{
	empty = || Store.(Dict.empty())

	insert : Store, Entity, a -> Store
	insert = |Store.(store), Entity.(ent, gen), comp| Store.(store.insert(ent, (gen, comp)))

	map = |Store.(store), fn| Store.(Dict.map(store, |_ent, (gen, v)| (gen, fn(v))))

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

Time := {
	dt : F32,
	total : F32,
}.{
	from_world : { time : Store(Time), .. } -> Store(Time)
	from_world = |storage| storage.time

	to_world : { time : Store(Time), ..r }, Store(Time) -> { time : Store(Time), ..r }
	to_world = |storage, store| {
		{ ..storage, time: store }
	}
}

Pos := { x : F32, y : F32 }.{
	from_world : { pos : Store(Pos), .. } -> Store(Pos)
	from_world = |storage| storage.pos

	to_world : { pos : Store(Pos), ..r }, Store(Pos) -> { pos : Store(Pos), ..r }
	to_world = |storage, store| {
		{ ..storage, pos: store }
	}
}

Pointer := {}.{
	from_world : { pointer : Store(Pointer), .. } -> Store(Pointer)
	from_world = |storage| storage.pointer

	to_world : { pointer : Store(Pointer), ..r }, Store(Pointer) -> { pointer : Store(Pointer), ..r }
	to_world = |storage, store| {
		{ ..storage, pointer: store }
	}
}

Components := [Center, Unused]
