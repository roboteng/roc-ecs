# Run with `roc test examples/sample.roc`
package [] { ecs: "../package/main.roc" }

import ecs.Ecs exposing [World]

## A component that stores an x,y pair for each `Ecs.Entity`
Position := { x : F32, y : F32 }.{
	to_col : List(Position) -> [Positions(List(Position))]
	to_col = |list| Positions(list)

	from_col : [Positions(List(Position)), ..] -> Try(List(Position), [WrongColumn])
	from_col = |col| match col {
		Positions(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## Different Nominal types are stored distinctly,
## even if they have the same underlying structure
Velocity := { x : F32, y : F32 }.{
	# Type annotations can be dropped, if you want
	to_col = |list| Velocities(list)
	from_col = |col| match col {
		Velocities(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## Resources are currently stored just like components
Clock := { dt : F32 }.{
	to_col = |list| Clocks(list)
	from_col = |col| match col {
		Clocks(clocks) => Ok(clocks)
		_ => Err(WrongColumn)
	}
}

update_positions = |world| {
	# We ask for a single `Clock`, returning early if we can't find it
	Clock.({ dt: dt }) =
		match world.single() {
			Ok(clock) => clock
			Err(_) => return world
		}

	# `World.map_with` allows you to write to one column, while reading from another
	world.map_with(
		# Queries have full type inference
		|Position.(pos), Velocity.(v)|
			Position.({ x: pos.x + v.x * dt, y: pos.y + v.y * dt }),
	)
}

expect {
	# `World`s store arbitrary components for each `Entity`, and the systems that operate on them
	world = World.empty()
		.add_system(update_positions)
		.spawn1(Clock.({ dt: 0.25 }))
		.spawn2(Position.({ x: 1, y: 2 }), Velocity.({ x: -1, y: 3 }))

	# `World.update` runs through all the systems saved in the `World`
	world_ticked = world.update()

	# Again, type annotations are optional, and inferred as `List((Ecs.Entity, Position))` because of the last line
	all_positions = world_ticked.query1()
	[{ x: 0.75, y: 2.75 }] == List.map(all_positions, |(_ent, Position.(p))| p)
}
