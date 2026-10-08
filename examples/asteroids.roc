app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0/5xecDmRJroKT9fnSiYsGdCKEzNWLnRKGtHJ5CxuCnpb9.tar.zst",
	ecs: "../package/main.roc",
}

import rr.App
import rr.Color
import rr.Devices
import rr.Draw
import rr.Random
import rr.Text
import ecs.Ecs
import ecs.RayEcs exposing [Clock, FillColor, FpsCounter, Gradient, Keyboard, Label, Layer, Position, Radius, Size, TextAlign, TextColor]

## Everything on screen is an entity in the world: `RayEcs` reads the devices
## into it on every update and draws it on every render.
Model(c) : { world : RayEcs.World(c, App.Input(Msg), Draw.Frame, [Exit(I64)]) }

## Nothing here waits, so there is no task to spawn and no message to fold in.
Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default
		.with_title("Asteroids")
		.with_size({ width: 800, height: 600 })
		.with_frame_pacing(Capped(120)),

	|io| {
		font = Draw.default_font!()
		seed = Random.seed(U64.to_u32_wrap(io.entropy!()))
		Ok({
			world: RayEcs.default(
				scene(font, seed)
					.add_system(restart)
					.add_system(steer)
					.add_system(fire)
					.add_system(advance)
					.add_system(expire)
					.add_system(shoot)
					.add_system(wreck)
					.add_system(next_wave)
					.add_system(blink)
					.add_system(hud),
				{ devices: Devices.none, draw!: draw_command! },
			).add_input(quit_on_escape).add_output(draw_outlines!),
		})
	},
)

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| Ok({ world: RayEcs.update!(model.world, input)? })

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| RayEcs.render!(model.world, frame)

# Tuning

width = 800

height = 600

center = { x: 400, y: 300 }

tau = 6.2831853

## Headings are radians clockwise from pointing right, so this is straight up.
up = 0 - tau / 4

## Radians per second.
turn_rate = 4.2

## Pixels per second, per second.
thrust = 260

## The share of its speed the ship loses each second.
drag = 0.35

ship_radius = 11

bullet_speed = 460

## Seconds a bullet flies for.
bullet_life = 1.1

## Seconds between shots while the trigger is held.
fire_delay = 0.22

## Seconds a new ship cannot be hit for.
shield_time = 2.5

radius_of = |size| match size {
	Large => 44
	Medium => 24
	Small => 12
}

speed_of = |size| match size {
	Large => 45
	Medium => 75
	Small => 115
}

points_for = |size| match size {
	Large => 20
	Medium => 50
	Small => 100
}

# Scene

at = |x, y| Position.({ x: x, y: y })

## The backdrop, the score line and the ship. `next_wave` brings the rocks.
scene = |font, seed| spawn_ship(
	Ecs.World.empty()
		.spawn3(at(0, 0), Size.({ width: width, height: height }), Gradient.(TopToBottom(Color.from_hex_rgb(0x0b1020), Color.from_hex_rgb(0x020308))))
		.spawn1(Game.({ score: 0, lives: 3, wave: 0, over: Bool.False, rng: seed }))
		.spawn(Ecs.Bundle.empty().add(Layer.(1)).add(at(16, 12)).add(Label.({ text: "", size: 24, font: font })).add(TextColor.(Color.white)).add(Hud.(Score))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(1)).add(at(784, 12)).add(Label.({ text: "", size: 24, font: font })).add(TextColor.(Color.white)).add(TextAlign.((Top, Right))).add(Hud.(Lives))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(1)).add(at(400, 300)).add(Label.({ text: "", size: 30, font: font })).add(TextColor.(Color.white)).add(TextAlign.((Middle, Center))).add(Hud.(Banner))).0
		.spawn(Ecs.Bundle.empty().add(Layer.(1)).add(at(400, 588)).add(Label.({ text: "A and D steer, W thrusts  -  Space fires  -  ESC exits", size: 16, font: font })).add(TextColor.(Color.from_hex_rgb(0x66708a))).add(TextAlign.((Bottom, Center)))).0
		.spawn4(Layer.(2), at(16, height - 32), FpsCounter.(32), TextColor.(Color.white)),
)

## A fresh ship in the middle of the screen, pointing up and shielded.
spawn_ship = |world| Ecs.World.spawn(
	world,
	Ecs.Bundle.empty()
		.add(Position.(center))
		.add(Velocity.({ x: 0, y: 0 }))
		.add(Heading.(up))
		.add(Collider.(ship_radius))
		.add(Outline.({ points: [{ x: 16, y: 0 }, { x: -12, y: -10 }, { x: -6, y: 0 }, { x: -12, y: 10 }], color: Color.white }))
		.add(Ship.({ cooldown: 0, shield: shield_time })),
).0

## A rock of `size`, between `near` and `far` away from `origin`, with a shape,
## a course and a spin drawn from the game's generator.
spawn_rock = |world, size, origin, near, far| match world.single() {
	Ok(Game.(game)) => {
		bearing = Random.step(game.rng, Random.f32(0, tau))
		distance = Random.next(bearing, Random.f32(near, far))
		course = Random.next(distance, Random.f32(0, tau))
		pace = Random.next(course, Random.f32(0.6, 1.4))
		spin = Random.next(pace, Random.f32(-1.2, 1.2))
		bumps = Random.next(spin, Random.list(Random.f32(0.72, 1), 10))
		speed = speed_of(size) * pace.value
		radius = radius_of(size)
		corners = bumps.value.fold(
			[],
			|points, bump| {
				angle = U64.to_f32(points.len()) * tau / 10
				points.append({ x: F32.cos(angle) * radius * bump, y: F32.sin(angle) * radius * bump })
			},
		)
		Ecs.World.spawn(
			world.map1(|Game.(_)| Game.({ ..game, rng: bumps.state })),
			Ecs.Bundle.empty()
				.add(at(origin.x + F32.cos(bearing.value) * distance.value, origin.y + F32.sin(bearing.value) * distance.value))
				.add(Velocity.({ x: F32.cos(course.value) * speed, y: F32.sin(course.value) * speed }))
				.add(Heading.(0))
				.add(Spin.(spin.value))
				.add(Collider.(radius))
				.add(Outline.({ points: corners, color: Color.from_hex_rgb(0xb9c2d6) }))
				.add(Asteroid.(size)),
		).0
	}
	Err(_) => world
}

spawn_rocks = |world, count, size, origin, near, far|
	if count == 0 {
		world
	} else {
		spawn_rocks(spawn_rock(world, size, origin, near, far), count - 1, size, origin, near, far)
	}

# Systems

## Ends the app when Escape goes down.
quit_on_escape = |world, _input| if pressed(world.inner, KeyEscape) Err(Exit(0)) else Ok(world)

## A and D turn the ship, W pushes it the way it points.
steer = |world| {
	dt = seconds(world)
	turn = (if held(world, KeyD) turn_rate * dt else 0) - (if held(world, KeyA) turn_rate * dt else 0)
	push = if held(world, KeyW) thrust * dt else 0
	slow = 1 - drag * dt
	world
		.map_with(|Heading.(angle), Ship.(_)| Heading.(angle + turn))
		.map_with2(|Velocity.(v), Heading.(angle), Ship.(_)| Velocity.({ x: v.x * slow + F32.cos(angle) * push, y: v.y * slow + F32.sin(angle) * push }))
}

## Runs down the ship's timers, then fires from its nose while Space is held.
fire = |world| {
	dt = seconds(world)
	cooled = world.map1(|Ship.(ship)| Ship.({ cooldown: F32.max(0, ship.cooldown - dt), shield: F32.max(0, ship.shield - dt) }))
	if held(cooled, KeySpace) {
		cooled.query3().fold(
			cooled,
			|next, (_, position, Heading.(angle), Ship.(ship))| if ship.cooldown > 0 {
				next
			} else {
				p = Position.get(position)
				Ecs.World.spawn(
					next,
					Ecs.Bundle.empty()
						.add(at(p.x + F32.cos(angle) * 16, p.y + F32.sin(angle) * 16))
						.add(Velocity.({ x: F32.cos(angle) * bullet_speed, y: F32.sin(angle) * bullet_speed }))
						.add(Collider.(2))
						.add(Radius.(2))
						.add(FillColor.(Color.white))
						.add(Bullet.(bullet_life)),
				).0
			},
		).map1(|Ship.(ship)| if ship.cooldown > 0 Ship.(ship) else Ship.({ ..ship, cooldown: fire_delay }))
	} else {
		cooled
	}
}

## Moves everything along its `Velocity` and turns whatever has a `Spin`.
## Something that leaves one edge by its own radius comes back on the other.
advance = |world| {
	dt = seconds(world)
	world
		.map_with2(
			|position, Velocity.(v), Collider.(margin)| {
				p = Position.get(position)
				Position.({ x: wrap(p.x + v.x * dt, width, margin), y: wrap(p.y + v.y * dt, height, margin) })
			},
		)
		.map_with(|Heading.(angle), Spin.(rate)| Heading.(angle + rate * dt))
}

wrap = |value, size, margin|
	if value < 0 - margin {
		value + size + margin * 2
	} else if value > size + margin {
		value - size - margin * 2
	} else {
		value
	}

## Bullets run out.
expire = |world| {
	dt = seconds(world)
	aged = world.map1(|Bullet.(left)| Bullet.(left - dt))
	despawn_all(aged, aged.query1().keep_if(|(_, Bullet.(left))| left <= 0).map(|(entity, _)| entity))
}

## A bullet inside a rock is spent, and the rock breaks up.
shoot = |world| {
	bullets = world.select().having(Bullet.to_col).query1().map(|(entity, position)| (entity, Position.get(position)))
	rocks(world).fold(
		world,
		|next, rock| match bullets.find_first(|(bullet, spot)| next.is_alive(bullet) and near(spot, rock.at, radius_of(rock.size))) {
			Ok((bullet, _)) => break_up(next.despawn(bullet).ok_or(next), rock)
			Err(_) => next
		},
	)
}

## Scores a rock and replaces it with two of the next size down.
break_up = |world, rock| {
	scored = world.despawn(rock.entity).ok_or(world).map1(|Game.(game)| Game.({ ..game, score: game.score + points_for(rock.size) }))
	match rock.size {
		Large => spawn_rocks(scored, 2, Medium, rock.at, 0, 14)
		Medium => spawn_rocks(scored, 2, Small, rock.at, 0, 8)
		Small => scored
	}
}

## An unshielded ship that touches a rock is lost. The next one starts in the
## middle; after the last one the game is over.
wreck = |world| {
	boulders = rocks(world)
	wrecked = world.query2().any(
		|(_, position, Ship.(ship))| ship.shield <= 0 and boulders.any(|rock| near(Position.get(position), rock.at, radius_of(rock.size) + ship_radius)),
	)
	if wrecked {
		match world.single() {
			Ok(Game.(game)) => {
				left = game.lives - 1
				cleared = despawn_all(world, ships(world)).map1(|Game.(_)| Game.({ ..game, lives: left, over: left == 0 }))
				if left == 0 cleared else spawn_ship(cleared)
			}
			Err(_) => world
		}
	} else {
		world
	}
}

## Once the last rock is gone, a bigger wave arrives around the ship.
next_wave = |world| match world.single() {
	Ok(Game.(game)) if !game.over and rocks(world).is_empty() => {
		origin = world.query2().fold(center, |_, (_, position, Ship.(_))| Position.get(position))
		spawn_rocks(world.map1(|Game.(_)| Game.({ ..game, wave: game.wave + 1 })), game.wave + 4, Large, origin, 230, 300)
	}
	_ => world
}

## Enter starts over once the game has ended.
restart = |world| match world.single() {
	Ok(Game.(game)) if game.over and pressed(world, KeyEnter) => {
		debris = rocks(world).map(|rock| rock.entity).concat(world.query1().map(|(entity, Bullet.(_))| entity))
		spawn_ship(despawn_all(world, debris).map1(|Game.(_)| Game.({ score: 0, lives: 3, wave: 0, over: Bool.False, rng: game.rng })))
	}
	_ => world
}

## A shielded ship flickers.
blink = |world| {
	found : Try(Clock, _)
	found = world.single()
	lit = match found {
		Ok(clock) => F32.sin(Clock.get(clock).total * 24) > 0
		Err(_) => Bool.True
	}
	world.map_with(
		|Outline.(outline), Ship.(ship)| Outline.({ ..outline, color: if ship.shield > 0 and !lit Color.with_alpha(Color.white, 60) else Color.white }),
	)
}

## Writes the score, the ships left and the banner into their labels.
hud = |world| match world.single() {
	Ok(Game.(game)) => world.map_with(
		|label, Hud.(part)| Label.(
			{
				..Label.get(label),
				text: match part {
					Score => "Score ${U64.to_str(game.score)}"
					Lives => "Ships ${U64.to_str(game.lives)}"
					Banner => if game.over "GAME OVER  -  Enter plays again" else ""
				},
			},
		),
	)
	Err(_) => world
}

## Draws every `Outline`, turned to its `Heading`, over what `RayEcs` drew.
draw_outlines! = |world, frame| {
	for shape in outlines(world.inner) {
		frame.convex_polygon!(shape)
	}
	Ok({})
}

## `draw_outlines!` as data, so it can be checked in an `expect`.
outlines = |world| world.query3().map(
	|(_, position, Heading.(angle), Outline.(outline))| {
		p = Position.get(position)
		cos = F32.cos(angle)
		sin = F32.sin(angle)
		{
			points: outline.points.map(|point| { x: p.x + point.x * cos - point.y * sin, y: p.y + point.x * sin + point.y * cos }),
			style: Draw.outlined(outline.color, 2),
		}
	},
)

# Helpers

## Seconds since the previous update.
seconds = |world| {
	found : Try(Clock, _)
	found = world.single()
	match found {
		Ok(clock) => Clock.get(clock).dt
		Err(_) => 0
	}
}

held = |world, key| {
	found : Try(Keyboard(_), _)
	found = world.single()
	match found {
		Ok(keyboard) => keyboard.down(key)
		Err(_) => Bool.False
	}
}

pressed = |world, key| {
	found : Try(Keyboard(_), _)
	found = world.single()
	match found {
		Ok(keyboard) => keyboard.pressed(key)
		Err(_) => Bool.False
	}
}

near = |a, b, reach| (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) < reach * reach

rocks = |world| world.query2().map(|(entity, position, Asteroid.(size))| { entity: entity, size: size, at: Position.get(position) })

ships = |world| world.query1().map(|(entity, Ship.(_))| entity)

despawn_all = |world, entities| entities.fold(world, |next, entity| next.despawn(entity).ok_or(next))

# Components

## Pixels per second.
Velocity := { x : F32, y : F32 }.{
	to_col : List(Velocity) -> [Velocities(List(Velocity))]
	to_col = |list| Velocities(list)

	from_col = |col| match col {
		Velocities(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## Which way an entity points, in radians clockwise from pointing right.
Heading := F32.{
	to_col : List(Heading) -> [Headings(List(Heading))]
	to_col = |list| Headings(list)

	from_col = |col| match col {
		Headings(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## How fast an entity's `Heading` turns, in radians per second.
Spin := F32.{
	to_col : List(Spin) -> [Spins(List(Spin))]
	to_col = |list| Spins(list)

	from_col = |col| match col {
		Spins(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## How far from its `Position` an entity reaches. `advance` lets it get this
## far past an edge before wrapping it.
Collider := F32.{
	to_col : List(Collider) -> [Colliders(List(Collider))]
	to_col = |list| Colliders(list)

	from_col = |col| match col {
		Colliders(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## With a `Position` and a `Heading`, draws a closed line through these
## points, which are relative to the position and turned to the heading.
Outline := { points : List({ x : F32, y : F32 }), color : Color.Rgba }.{
	to_col : List(Outline) -> [Outlines(List(Outline))]
	to_col = |list| Outlines(list)

	from_col = |col| match col {
		Outlines(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## The player's ship: seconds until it can fire again, and seconds of shield
## it has left.
Ship := { cooldown : F32, shield : F32 }.{
	to_col : List(Ship) -> [Ships(List(Ship))]
	to_col = |list| Ships(list)

	from_col = |col| match col {
		Ships(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Asteroid := [Large, Medium, Small].{
	to_col : List(Asteroid) -> [Asteroids(List(Asteroid))]
	to_col = |list| Asteroids(list)

	from_col = |col| match col {
		Asteroids(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## A shot, and the seconds it has left.
Bullet := F32.{
	to_col : List(Bullet) -> [Bullets(List(Bullet))]
	to_col = |list| Bullets(list)

	from_col = |col| match col {
		Bullets(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## The one entity that keeps score. `rng` is where every random number in the
## game comes from, so a seed decides a whole run.
Game := { score : U64, lives : U64, wave : U64, over : Bool, rng : Random.State }.{
	to_col : List(Game) -> [Games(List(Game))]
	to_col = |list| Games(list)

	from_col = |col| match col {
		Games(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## Marks a `Label` that `hud` keeps up to date, and says with what.
Hud := [Score, Lives, Banner].{
	to_col : List(Hud) -> [Huds(List(Hud))]
	to_col = |list| Huds(list)

	from_col = |col| match col {
		Huds(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

# Tests

## A world as it is after `init!`, before the first update.
fresh = || RayEcs.spawn_devices(scene(Text.font_stub, Random.seed(7)), Devices.none)

## One update's worth of input: `seconds` long, with these keys held.
tick = |world, dt, keys| {
	input : App.Input([])
	input = App.Input.for_tests({})
		.with_devices(keys.fold(Devices.none, |devices, key| devices.with_key_down(key)))
		.with_time({ cycle_count: 1, simulation_nanos: 0, monotonic_nanos: 0, elapsed_seconds: dt })
	RayEcs.write_devices(world, input)
}

## A world with no shield left on the ship.
unshielded = |world| world.map1(|Ship.(ship)| Ship.({ ..ship, shield: 0 }))

score = |world| match world.single() {
	Ok(Game.(game)) => game.score
	Err(_) => 0
}

lives = |world| match world.single() {
	Ok(Game.(game)) => game.lives
	Err(_) => 0
}

sizes = |world| rocks(world).map(|rock| rock.size)

# `RayEcs` draws the backdrop, four labels and FPS; the ship is an outline.
expect RayEcs.scene(fresh()).len() == 6 and outlines(fresh()).len() == 1

# The first wave is four large rocks, none of them on top of the ship.
expect {
	world = next_wave(fresh())
	sizes(world) == [Large, Large, Large, Large]
		and rocks(world).all(|rock| !near(rock.at, center, 200))
			and rocks(next_wave(world)).len() == 4
}

# Thrust pushes the ship the way it points: up, to begin with.
expect {
	world = advance(steer(tick(fresh(), 0.5, [KeyW])))
	world.query2().map(|(_, position, Ship.(_))| Position.get(position)).all(|p| p.x > 399.9 and p.x < 400.1 and p.y < 300)
}

# Something that leaves one edge by its own radius comes back on the other.
expect wrap(811, 800, 10) == -9 and wrap(-11, 800, 10) == 809 and wrap(805, 800, 10) == 805

# Holding Space fires one bullet, then nothing until the ship has cooled down.
expect {
	once = fire(tick(fresh(), 0.01, [KeySpace]))
	twice = fire(once)
	later = fire(tick(twice, fire_delay, [KeySpace]))
	bullets = |world| world.select().having(Bullet.to_col).count()
	bullets(once) == 1 and bullets(twice) == 1 and bullets(later) == 2
}

# A bullet runs out after `bullet_life` seconds.
expect {
	shot = fire(tick(fresh(), 0.01, [KeySpace]))
	expire(tick(shot, bullet_life - 0.1, [])).select().having(Bullet.to_col).count() == 1
		and expire(tick(shot, bullet_life + 0.1, [])).select().having(Bullet.to_col).count() == 0
}

# A bullet inside a large rock is spent, and the rock becomes two medium ones.
expect {
	world = spawn_rock(fresh(), Large, { x: 100, y: 100 }, 0, 1)
		.spawn2(at(110, 100), Bullet.(1))
		.spawn2(at(600, 500), Bullet.(1))
	hit = shoot(world)
	sizes(hit) == [Medium, Medium] and score(hit) == 20 and hit.select().having(Bullet.to_col).count() == 1
}

# A small rock is just gone.
expect {
	hit = shoot(spawn_rock(fresh(), Small, { x: 100, y: 100 }, 0, 1).spawn2(at(100, 100), Bullet.(1)))
	sizes(hit) == [] and score(hit) == 100
}

# A rock on the ship costs a life, unless the ship is still shielded.
expect {
	world = spawn_rock(fresh(), Large, center, 0, 1)
	lives(wreck(world)) == 3 and lives(wreck(unshielded(world))) == 2 and ships(wreck(unshielded(world))).len() == 1
}

# Losing the last ship ends the game, and Enter starts a new one.
expect {
	last = spawn_rock(fresh(), Large, center, 0, 1).map1(|Game.(game)| Game.({ ..game, lives: 1, score: 70 }))
	over = hud(wreck(unshielded(last)))
	banner = |world| world.query2().keep_if(|(_, _, Hud.(part))| part == Banner).map(|(_, label, _)| Label.get(label).text)
	input : App.Input([])
	input = App.Input.for_tests({}).with_devices(Devices.none.with_key_pressed(KeyEnter))
	again = hud(restart(RayEcs.write_devices(over, input)))
	ships(over) == [] and banner(over) == ["GAME OVER  -  Enter plays again"] and next_wave(over).len() == over.len()
		and ships(again).len() == 1 and lives(again) == 3 and score(again) == 0 and sizes(again) == [] and banner(again) == [""]
}

# Platform adapter: the package only produces commands.
draw_command! = |frame, command| {
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
	Ok({})
}
