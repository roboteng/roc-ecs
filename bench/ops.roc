# Workloads for timing the operations that change a world. Each one builds a
# world of as many entities as its second argument says and then runs the
# operation named by its first on every entity. There is no clock in pure Roc,
# so `bench/scaling.py` builds this once and times it from outside across world
# sizes:
#
#     python3 bench/scaling.py
app [main!] { ecs: "../package/main.roc" }

import ecs.Ecs

Pos := { x : I64, y : I64 }.{
	to_col = |list| Positions(list)

	from_col = |col| match col {
		Positions(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Vel := { dx : I64, dy : I64 }.{
	to_col = |list| Velocities(list)

	from_col = |col| match col {
		Velocities(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Tag := I64.{
	to_col = |list| Tags(list)

	from_col = |col| match col {
		Tags(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

## How many times `map` goes over the world.
passes = 20

## Spawns `count` entities into one archetype. The world is only ever held in
## `$world`, so every call gets it with nothing else pointing at it: if a list
## is copied here, it is the operation that made the copy necessary.
populate = |count| {
	var $world = Ecs.World.empty({})
	var $entities = List.with_capacity(count)
	var $i = 0
	while $i < count {
		n = $i.to_i64_wrap()
		(next, entity) = $world.spawn(Ecs.Bundle.empty().add(Pos.({ x: n, y: n })).add(Vel.({ dx: n, dy: n })))
		$world = next
		$entities = $entities.append(entity)
		$i = $i + 1
	}
	($world, $entities)
}

## The world after `op` has been run on every entity, oldest first.
##
## A failing `op` crashes instead of leaving the world as it was: keeping the
## old world around for that case would be a second reference to it, and every
## `op` would then have to copy what it changes.
each = |(world, entities), op| {
	var $world = world
	for entity in entities {
		$world = match op($world, entity) {
			Ok(next) => next
			Err(_) => crash "bench: an operation failed on an entity that should be alive"
		}
	}
	$world
}

## Runs a workload and returns a number that says it did all of its work.
run : Str, U64 -> Try(U64, [UnknownOp])
run = |op, count| match op {
	"spawn" => Ok(populate(count).0.len())
	# Oldest first, so every despawn but the last moves another entity
	# into the hole.
	"despawn" => Ok(count - each(populate(count), |world, entity| world.despawn(entity)).len())
	# Every spawn after the first reuses the id the despawn before it gave up.
	"churn" => Ok(
		each(
			populate(count),
			|world, entity| {
				without = world.despawn(entity)?
				Ok(without.spawn2(Pos.({ x: 0, y: 0 }), Vel.({ dx: 0, dy: 0 })))
			},
		).len(),
	)
	# A component the entity already has: overwritten where it is.
	"replace" => Ok(each(populate(count), |world, entity| world.insert(entity, Pos.({ x: 1, y: 1 }))).query1().keep_if(|(_, Pos.(p))| p.x == 1).len())
	# A component it does not have: every entity moves to a second archetype.
	"insert" => Ok(each(populate(count), |world, entity| world.insert(entity, Tag.(7))).query1().keep_if(|(_, Tag.(t))| t == 7).len())
	# There and back again.
	"take" => {
		(world, entities) = populate(count)
		tagged = each((world, entities), |w, entity| w.insert(entity, Tag.(7)))
		untagged = each(
			(tagged, entities),
			|w, entity| {
				(next, Tag.(_)) = w.take(entity)?
				Ok(next)
			},
		)
		Ok(untagged.select().without(Tag.to_col).count())
	}
	"get" => {
		(world, entities) = populate(count)
		Ok(
			entities.fold(
				0,
				|found, entity| {
					got : Try(Vel, _)
					got = world.get(entity)
					if got.is_ok() found + 1 else found
				},
			),
		)
	}
	"map" => {
		var $world = populate(count).0
		var $pass = 0
		while $pass < passes {
			$world = $world.map_with(|Pos.(p), Vel.(v)| Pos.({ x: p.x + v.dx, y: p.y + v.dy }))
			$pass = $pass + 1
		}
		Ok($world.len())
	}
	_ => Err(UnknownOp)
}

main! = |args| match args {
	[op, count] => {
		done = run(op, U64.from_str(count)?)?
		echo!("${op} ${done.to_str()}")
		Ok({})
	}
	_ => {
		echo!("usage: ops <spawn|despawn|churn|replace|insert|take|get|map> <entities>")
		Err(Exit(2))
	}
}

expect run("spawn", 50) == Ok(50)
expect run("despawn", 50) == Ok(50)
expect run("churn", 50) == Ok(50)
expect run("replace", 50) == Ok(50)
expect run("insert", 50) == Ok(50)
expect run("take", 50) == Ok(50)
expect run("get", 50) == Ok(50)
expect run("map", 50) == Ok(50)
expect run("nonsense", 50) == Err(UnknownOp)
