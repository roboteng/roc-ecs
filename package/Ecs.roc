## An archetype ECS.
##
## A component is any nominal type that says which column it lives in:
##
## ```roc
## Pos := { x : F32, y : F32 }.{
##     to_col : List(Pos) -> [Positions(List(Pos))]
##     to_col = |list| Positions(list)
##
##     from_col = |col| match col {
##         Positions(list) => Ok(list)
##         _ => Err(WrongColumn)
##     }
## }
## ```
##
## `col` is the tag union of every column the app uses. Each component only
## names its own tag, so the union is never written out by hand unless you want
## to: it is whatever the components you actually use add up to.
##
## Entities with the same set of components share an archetype, which keeps one
## densely packed `List` per component. Queries and maps never look at single
## entities: they pick the archetypes that have the columns they need and work
## on whole lists.
Ecs :: [].{

	## A handle to a spawned entity. Handles to despawned entities stay
	## invalid forever: the id is reused, but under a new generation.
	Entity :: { id : EntityId, gen : Gen }.{
		is_eq : _
		to_hash : _
	}

	## The components for one entity, before it is spawned.
	Bundle(col) :: List(Column(col)).{
		empty : () -> Bundle(col)
		empty = || Bundle.([])

		## Adding the same component type twice keeps the last one.
		add : Bundle(col), c -> Bundle(col) where [c.Component(col)]
		add = |Bundle.(columns), component| {
			column = column_of([component])
			Bundle.(columns.drop_if(|other| (column.matches)(other.data)).append(column))
		}
	}

	World(col, res) :: {
		archetypes : List(Archetype(col)),
		slots : List(Slot),
		despawned : List(Entity),
		systems : List(World(col, res) -> World(col, res)),
		resources : res,
	}.{
		empty : res -> World(col, res)
		empty = |resources| World.({ archetypes: [], slots: [], despawned: [], systems: [], resources: resources })

		## The resource the caller expects, picked out of the value handed to
		## `empty`. Which one is decided by the type, as with components:
		##
		##     Clock.({ dt }) = world.resource()
		resource : World(col, res) -> r where [r.Resource(res)]
		resource = |world| {
			R : r
			R.from_res(world.resources)
		}

		## Replaces the resources with what `change` makes of them:
		##
		##     world.map_resources(|res| { ..res, tick: Tick.(n + 1) })
		map_resources : World(col, res), (res -> res) -> World(col, res)
		map_resources = |world, change| World.(
			{
				archetypes: world.archetypes,
				slots: world.slots,
				despawned: world.despawned,
				systems: world.systems,
				resources: change(world.resources),
			},
		)

		## Systems run in the order they were added, once per `update`.
		add_system : World(col, res), (World(col, res) -> World(col, res)) -> World(col, res)
		add_system = |world, system| World.(
			{
				archetypes: world.archetypes,
				slots: world.slots,
				despawned: world.despawned,
				systems: world.systems.append(system),
				resources: world.resources,
			},
		)

		update : World(col, res) -> World(col, res)
		update = |world| world.systems.fold(world, |next, system| system(next))

		## Number of live entities.
		len : World(col, res) -> U64
		len = |world| world.archetypes.fold(0, |total, arch| total + arch.entities.len())

		spawn : World(col, res), Bundle(col) -> (World(col, res), Entity)
		spawn = |World.(world), Bundle.(row)| {
			spawned = sound(spawn_row(world.archetypes, world.slots, world.despawned, row))
			(
				World.({ archetypes: spawned.archetypes, slots: spawned.slots, despawned: spawned.despawned, systems: world.systems, resources: world.resources }),
				spawned.entity,
			)
		}

		## `spawn1` to `spawn4` return only the world so that setup code can
		## chain. Use `spawn` when you need the `Entity` back.
		spawn1 : World(col, res), a -> World(col, res) where [a.Component(col)]
		spawn1 = |world, a| world.spawn(Bundle.empty().add(a)).0

		spawn2 : World(col, res), a, b -> World(col, res) where [a.Component(col), b.Component(col)]
		spawn2 = |world, a, b| world.spawn(Bundle.empty().add(a).add(b)).0

		spawn3 : World(col, res), a, b, c -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		spawn3 = |world, a, b, c| world.spawn(Bundle.empty().add(a).add(b).add(c)).0

		spawn4 : World(col, res), a, b, c, d -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col)]
		spawn4 = |world, a, b, c, d| world.spawn(Bundle.empty().add(a).add(b).add(c).add(d)).0

		despawn : World(col, res), Entity -> Try(World(col, res), [NoSuchEntity])
		despawn = |World.(world), entity| {
			seat = locate(world.slots, entity)?
			left = sound(retire(world.archetypes, world.slots, world.despawned, entity, seat))
			Ok(World.({ archetypes: left.archetypes, slots: left.slots, despawned: left.despawned, systems: world.systems, resources: world.resources }))
		}

		is_alive : World(col, res), Entity -> Bool
		is_alive = |world, entity| locate(world.slots, entity).is_ok()

		## Which component to read is decided by the type the caller expects:
		##
		##     Pos.(pos) = world.get(entity)?
		get : World(col, res), Entity -> Try(c, [NoSuchEntity, MissingComponent]) where [c.Component(col)]
		get = |World.(world), entity| {
			seat = locate(world.slots, entity)?
			Ok(sound(component_at(world.archetypes, seat))?)
		}

		## Adds a component to an entity, or replaces the one it already has.
		## Adding moves the entity to the archetype for its new set of
		## components.
		insert : World(col, res), Entity, c -> Try(World(col, res), [NoSuchEntity]) where [c.Component(col)]
		insert = |World.(world), entity, component| {
			seat = locate(world.slots, entity)?
			changed = sound(put(world.archetypes, world.slots, entity, seat, component))
			Ok(World.({ archetypes: changed.archetypes, slots: changed.slots, despawned: world.despawned, systems: world.systems, resources: world.resources }))
		}

		## Removes a component from an entity and hands it back. As with
		## `get`, the expected type picks the component:
		##
		##     (world2, Stunned.(_)) = world.take(entity)?
		take : World(col, res), Entity -> Try((World(col, res), c), [NoSuchEntity, MissingComponent]) where [c.Component(col)]
		take = |World.(world), entity| {
			seat = locate(world.slots, entity)?
			component = sound(component_at(world.archetypes, seat))?
			taken = column_of([component])
			moved = sound(migrate(world.archetypes, world.slots, entity, seat, |row| row.drop_if(|cell| (taken.matches)(cell.data))))
			Ok((
				World.({ archetypes: moved.archetypes, slots: moved.slots, despawned: world.despawned, systems: world.systems, resources: world.resources }),
				component,
			))
		}

		## Start a filtered query. `world.query2()` is short for
		## `world.select().query2()`.
		select : World(col, res) -> Selection(col)
		select = |world| Selection.({ archetypes: world.archetypes, mask: world.archetypes.map(|_| Bool.True) })

		query1 : World(col, res) -> List((Entity, a)) where [a.Component(col)]
		query1 = |world| world.select().query1()

		query2 : World(col, res) -> List((Entity, a, b)) where [a.Component(col), b.Component(col)]
		query2 = |world| world.select().query2()

		query3 : World(col, res) -> List((Entity, a, b, c)) where [a.Component(col), b.Component(col), c.Component(col)]
		query3 = |world| world.select().query3()

		query4 : World(col, res) -> List((Entity, a, b, c, d)) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col)]
		query4 = |world| world.select().query4()

		query5 : World(col, res) -> List((Entity, a, b, c, d, e)) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col), e.Component(col)]
		query5 = |world| world.select().query5()

		single : World(col, res) -> Try(a, [NoMatch, ManyMatches]) where [a.Component(col)]
		single = |world| world.select().single()

		## Rewrites one component of every entity that has it.
		map1 : World(col, res), (a -> a) -> World(col, res) where [a.Component(col)]
		map1 = |world, fn| world.map1_in(world.select(), fn)

		## Rewrites two components of every entity that has both.
		map2 : World(col, res), (a, b -> (a, b)) -> World(col, res) where [a.Component(col), b.Component(col)]
		map2 = |world, fn| world.map2_in(world.select(), fn)

		map3 : World(col, res), (a, b, c -> (a, b, c)) -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		map3 = |world, fn| world.map3_in(world.select(), fn)

		## Rewrites the first component while reading the second: the
		## equivalent of a `(&mut A, &B)` query.
		map_with : World(col, res), (a, b -> a) -> World(col, res) where [a.Component(col), b.Component(col)]
		map_with = |world, fn| world.map_with_in(world.select(), fn)

		map_with2 : World(col, res), (a, b, c -> a) -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		map_with2 = |world, fn| world.map_with2_in(world.select(), fn)

		## `map1` on only the archetypes a selection kept:
		##
		##     world.map1_in(world.select().without(Frozen.to_col), |Pos.(p)| ...)
		##
		## Only the selection's choice of archetypes is used, so the selection
		## can come from an earlier version of this world. Archetypes the world
		## has gained since are not selected.
		map1_in : World(col, res), Selection(col), (a -> a) -> World(col, res) where [a.Component(col)]
		map1_in = |World.(world), Selection.(selection), fn| {
			mask = selection.mask
			changed = sound(change_selected(world.archetypes, mask, |arch| plan1(arch, fn), |arch, index| map_column(arch, index, |la| Ok(la.map(fn)))))
			World.({ archetypes: changed, slots: world.slots, despawned: world.despawned, systems: world.systems, resources: world.resources })
		}

		map2_in : World(col, res), Selection(col), (a, b -> (a, b)) -> World(col, res) where [a.Component(col), b.Component(col)]
		map2_in = |World.(world), Selection.(selection), fn| {
			mask = selection.mask
			changed = sound(
				change_selected(
					world.archetypes,
					mask,
					|arch| plan2(arch, fn),
					|arch, (ia, ib, out)| {
						with_a = map_column(arch, ia, |_| Ok(out.map(|row| row.0)))?
						map_column(with_a, ib, |_| Ok(out.map(|row| row.1)))
					},
				),
			)
			World.({ archetypes: changed, slots: world.slots, despawned: world.despawned, systems: world.systems, resources: world.resources })
		}

		map3_in : World(col, res), Selection(col), (a, b, c -> (a, b, c)) -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		map3_in = |World.(world), Selection.(selection), fn| {
			mask = selection.mask
			changed = sound(
				change_selected(
					world.archetypes,
					mask,
					|arch| plan3(arch, fn),
					|arch, (ia, ib, ic, out)| {
						with_a = map_column(arch, ia, |_| Ok(out.map(|row| row.0)))?
						with_b = map_column(with_a, ib, |_| Ok(out.map(|row| row.1)))?
						map_column(with_b, ic, |_| Ok(out.map(|row| row.2)))
					},
				),
			)
			World.({ archetypes: changed, slots: world.slots, despawned: world.despawned, systems: world.systems, resources: world.resources })
		}

		map_with_in : World(col, res), Selection(col), (a, b -> a) -> World(col, res) where [a.Component(col), b.Component(col)]
		map_with_in = |World.(world), Selection.(selection), fn| {
			mask = selection.mask
			changed = sound(change_selected(world.archetypes, mask, |arch| plan_with(arch, fn), |arch, (index, lb)| map_column(arch, index, |la| zip_with(la, lb, fn))))
			World.({ archetypes: changed, slots: world.slots, despawned: world.despawned, systems: world.systems, resources: world.resources })
		}

		map_with2_in : World(col, res), Selection(col), (a, b, c -> a) -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		map_with2_in = |World.(world), Selection.(selection), fn| {
			mask = selection.mask
			changed = sound(change_selected(world.archetypes, mask, |arch| plan_with2(arch, fn), |arch, (index, lb, lc)| map_column(arch, index, |la| zip_with2(la, lb, lc, fn))))
			World.({ archetypes: changed, slots: world.slots, despawned: world.despawned, systems: world.systems, resources: world.resources })
		}
	}

	## The archetypes of a world, narrowed to some of them.
	##
	## The components a query or map asks for already narrow it, so `having` is
	## for components you want present but don't need to read, and `without`
	## is for ones that must be absent. Both take a component's `to_col` to
	## say which type they mean:
	##
	##     world.select().without(Frozen.to_col).query2()
	##
	## To change only the selected entities, hand the selection to one of the
	## world's `_in` maps:
	##
	##     world.map_with_in(world.select().without(Frozen.to_col), |Pos.(p), Vel.(v)| ...)
	##
	## A map changes the world, not the selection: of the selection it only
	## uses which archetypes were kept.
	Selection(col) :: { archetypes : List(Archetype(col)), mask : List(Bool) }.{
		having : Selection(col), (List(c) -> col) -> Selection(col) where [c.Component(col)]
		having = |selection, witness| narrow(selection, |arch| holds(arch, witness))

		without : Selection(col), (List(c) -> col) -> Selection(col) where [c.Component(col)]
		without = |selection, witness| narrow(selection, |arch| !holds(arch, witness))

		## Number of entities in the selected archetypes.
		count : Selection(col) -> U64
		count = |selection| gather(selection, |arch| Ok(arch.entities)).len()

		query1 : Selection(col) -> List((Entity, a)) where [a.Component(col)]
		query1 = |selection| gather(
			selection,
			|arch| {
				la = fetch(arch)?
				Ok(List.map2(arch.entities, la, |entity, a| (entity, a)))
			},
		)

		query2 : Selection(col) -> List((Entity, a, b)) where [a.Component(col), b.Component(col)]
		query2 = |selection| gather(
			selection,
			|arch| {
				la = fetch(arch)?
				lb = fetch(arch)?
				Ok(List.map3(arch.entities, la, lb, |entity, a, b| (entity, a, b)))
			},
		)

		query3 : Selection(col) -> List((Entity, a, b, c)) where [a.Component(col), b.Component(col), c.Component(col)]
		query3 = |selection| gather(
			selection,
			|arch| {
				la = fetch(arch)?
				lb = fetch(arch)?
				lc = fetch(arch)?
				Ok(List.map4(arch.entities, la, lb, lc, |entity, a, b, c| (entity, a, b, c)))
			},
		)

		query4 : Selection(col) -> List((Entity, a, b, c, d)) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col)]
		query4 = |selection| gather(
			selection,
			|arch| {
				la = fetch(arch)?
				lb = fetch(arch)?
				lc = fetch(arch)?
				ld = fetch(arch)?
				abc = List.map4(arch.entities, la, lb, lc, |entity, a, b, c| (entity, a, b, c))
				Ok(List.map2(abc, ld, |(entity, a, b, c), d| (entity, a, b, c, d)))
			},
		)

		query5 : Selection(col) -> List((Entity, a, b, c, d, e)) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col), e.Component(col)]
		query5 = |selection| gather(
			selection,
			|arch| {
				la = fetch(arch)?
				lb = fetch(arch)?
				lc = fetch(arch)?
				ld = fetch(arch)?
				le = fetch(arch)?
				abc = List.map4(arch.entities, la, lb, lc, |entity, a, b, c| (entity, a, b, c))
				Ok(List.map3(abc, ld, le, |(entity, a, b, c), d, e| (entity, a, b, c, d, e)))
			},
		)

		## The component of the only entity that has one. Handy for
		## resource-like singletons such as a clock.
		single : Selection(col) -> Try(a, [NoMatch, ManyMatches]) where [a.Component(col)]
		single = |selection| {
			found : List(a)
			found = gather(selection, |arch| fetch(arch))
			if found.len() > 1 {
				Err(ManyMatches)
			} else {
				found.first().map_err(|_| NoMatch)
			}
		}

	}
}

## What a type needs in order to be a component stored in `col`.
c.Component(col) :
	where [
		c.to_col : List(c) -> col,
		c.from_col : col -> Try(List(c), [WrongColumn]),
	]

## What a type needs in order to be a resource kept in `res`: state that
## belongs to the world as a whole rather than to any entity, such as a clock.
r.Resource(res) :
	where [
		r.from_res : res -> r,
	]

## One component's storage in one archetype, together with the operations that
## have to work without knowing the component type: moving an entity between
## archetypes touches every column it has, not just the ones named in the call.
## The closures are built in `column_of`, the one place the type is known.
##
## Each closure is handed the `col` to work on, and that `col` could hold some
## other component, so each one can fail with `WrongColumn`. `grow`, `shrink`,
## `lone` and `hollow` pair a column's closures with its own `data`: use those.
Column(col) : {
	data : col,

	## An empty column for the same component.
	blank : () -> col,

	## Whether the other column holds the same component.
	matches : col -> Bool,

	## The first column with the second one's rows appended.
	push_from : col, col -> Try(col, Fault),

	## The column without a row, which the last row is moved into.
	drop_swap : col, U64 -> Try(col, Fault),

	## A column holding a copy of one row.
	copy_row : col, U64 -> Try(col, Fault),
}

## One entity's components, each in a column of its own: what a `Bundle` holds,
## and what `row_at` copies out of an archetype.
Row(col) : List(Column(col))

Archetype(col) : {
	entities : List(Ecs.Entity),
	columns : List(Column(col)),
}

EntityId : U32

Gen : U32

## Where an entity's handle is kept: a row of one of the world's `archetypes`,
## or a row of its `despawned` list.
ArchetypeId : [Despawned, Live(U64)]

Slot : { gen : Gen, arch : ArchetypeId, row : U64 }

## A live entity's slot, with the archetype resolved to an index into
## `archetypes`.
Seat : { gen : Gen, arch : U64, row : U64 }

## An error that no caller can cause: the world's own bookkeeping disagrees
## with itself. Everything that changes a world can return one, and only
## `sound` gets rid of one.
Fault : [OutOfBounds, WrongColumn, TooManyEntities]

## Where a `Fault` stops. The public functions call this on the one step that
## does their work, so a fault is reported at the call that found it instead of
## turning into a world that is quietly wrong.
sound : Try(a, Fault) -> a
sound = |attempt| match attempt {
	Ok(value) => value
	Err(fault) => crash "Ecs: the world's bookkeeping is broken (${Str.inspect(fault)}). This is a bug in Ecs, not in the code calling it."
}

## Changes one element with a function that can fail, in place when nothing
## else holds the list.
##
## `spare` sits in the list while the element is out of it. That is what lets
## `change` update the element in place: the list no longer points at it.
## `List.update` does the same for a `change` that cannot fail. `List.map_try`
## leaves the element shared with the list, so changing it copies it (see
## ARCHITECTURE.md).
try_update : List(a), U64, a, (a -> Try(a, [OutOfBounds, ..errs])) -> Try(List(a), [OutOfBounds, ..errs])
try_update = |list, index, spare, change| {
	{ list: rest, prev } = list.replace(index, spare)?
	Ok(rest.set(index, change(prev)?)?)
}

column_of : List(c) -> Column(col) where [c.Component(col)]
column_of = |items| {
	C : c
	{
		data: C.to_col(items),
		blank: || C.to_col([]),
		matches: |other| C.from_col(other).is_ok(),
		# In each of these, the list that is changed is unwrapped by a
		# `match` and changed in its `Ok` branch. Unwrapping it with `?`
		# reads the same and copies the list (see ARCHITECTURE.md).
		push_from: |dst, src| {
			from = C.from_col(src)?
			match C.from_col(dst) {
				Ok(into) => Ok(C.to_col(into.concat(from)))
				Err(WrongColumn) => Err(WrongColumn)
			}
		},
		drop_swap: |data, row| {
			match C.from_col(data) {
				# `List.drop_swap` gives the list back unchanged for a row
				# it does not have.
				Ok(list) => if row < list.len() {
					Ok(C.to_col(list.drop_swap(row)))
				} else {
					Err(OutOfBounds)
				}
				Err(WrongColumn) => Err(WrongColumn)
			}
		},
		copy_row: |data, row| {
			list = C.from_col(data)?
			Ok(C.to_col([list.get(row)?]))
		},
	}
}

## Appends the rows of `cell`, which has to hold the same component.
grow : Column(col), Column(col) -> Try(Column(col), Fault)
grow = |column, cell| {
	data = (column.push_from)(column.data, cell.data)?
	Ok({ ..column, data: data })
}

shrink : Column(col), U64 -> Try(Column(col), Fault)
shrink = |column, row| {
	data = (column.drop_swap)(column.data, row)?
	Ok({ ..column, data: data })
}

## A column of the same component holding a copy of one row.
lone : Column(col), U64 -> Try(Column(col), Fault)
lone = |column, row| {
	data = (column.copy_row)(column.data, row)?
	Ok({ ..column, data: data })
}

## The column with no rows.
hollow : Column(col) -> Column(col)
hollow = |column| { ..column, data: (column.blank)() }

## A `spare` for `try_update` on the column at `index`.
##
## This is a function of its own because of what it lets go of when it
## returns: built in the loop that calls `try_update`, the spare leaves a
## reference to the column behind, and the column is then copied.
spare_at : List(Column(col)), U64 -> Try(Column(col), Fault)
spare_at = |columns, index| Ok(hollow(columns.get(index)?))

fetch : Archetype(col) -> Try(List(c), [Missing]) where [c.Component(col)]
fetch = |arch| {
	C : c
	arch.columns.fold_until(
		Err(Missing),
		|missing, column| match C.from_col(column.data) {
			Ok(list) => Break(Ok(list))
			Err(_) => Continue(missing)
		},
	)
}

holds : Archetype(col), (List(c) -> col) -> Bool where [c.Component(col)]
holds = |arch, _witness| {
	C : c
	arch.columns.any(|column| C.from_col(column.data).is_ok())
}

narrow : Ecs.Selection(col), (Archetype(col) -> Bool) -> Ecs.Selection(col)
narrow = |selection, keep| Ecs.Selection.(
	{
		archetypes: selection.archetypes,
		mask: List.map2(selection.mask, selection.archetypes, |selected, arch| selected and keep(arch)),
	},
)

## The rows `rows_of` finds in each selected archetype. An archetype that is
## `Missing` a component it was asked for has no rows to give.
gather : Ecs.Selection(col), (Archetype(col) -> Try(List(row), [Missing])) -> List(row)
gather = |selection, rows_of| List.map2(selection.mask, selection.archetypes, |selected, arch| (selected, arch)).fold(
	[],
	|rows, (selected, arch)| if selected {
		match rows_of(arch) {
			Ok(found) => rows.concat(found)
			Err(Missing) => rows
		}
	} else {
		rows
	},
)

## Changes, in place, each archetype that `mask` selects and in which `plan`
## finds what `apply` needs. An archetype past the end of `mask` was added
## after the selection was made, and is not selected.
##
## `plan` only reads, so an archetype it finds `Missing` something in is left
## as it was without having been taken out of the list. `apply` gets the
## archetype with nothing else pointing at it.
change_selected : List(Archetype(col)), List(Bool), (Archetype(col) -> Try(p, [Missing])), (Archetype(col), p -> Try(Archetype(col), Fault)) -> Try(List(Archetype(col)), Fault)
change_selected = |archetypes, mask, plan, apply| {
	var $archetypes = archetypes
	var $index = 0
	for selected in mask {
		if selected {
			match plan_at($archetypes, $index, plan)? {
				Ok(planned) => {
					$archetypes = try_update($archetypes, $index, { entities: [], columns: [] }, |arch| apply(arch, planned))?
				}
				Err(Missing) => {}
			}
		}
		$index = $index + 1
	}
	Ok($archetypes)
}

## `plan` run on one archetype, in a function of its own so that the
## reference it reads through is let go of before the archetype is changed.
## A selection from another world can be longer than this one's archetypes,
## and an archetype that is not there has nothing to plan.
plan_at : List(Archetype(col)), U64, (Archetype(col) -> Try(p, [Missing])) -> Try(Try(p, [Missing]), Fault)
plan_at = |archetypes, index, plan| match archetypes.get(index) {
	Ok(arch) => Ok(plan(arch))
	Err(OutOfBounds) => Ok(Err(Missing))
}

## Takes the list out of the column at `index` and puts back what `change`
## makes of it. With the list out of the column, `change` holds the only
## reference to it, so `List.map` and the like reuse it.
map_column : Archetype(col), U64, (List(c) -> Try(List(c), Fault)) -> Try(Archetype(col), Fault) where [c.Component(col)]
map_column = |{ entities, columns }, index, change| {
	C : c
	spare = spare_at(columns, index)?
	changed = try_update(
		columns,
		index,
		spare,
		|column| match C.from_col(column.data) {
			Ok(list) => {
				data = change(list)?
				Ok({ ..column, data: C.to_col(data) })
			}
			Err(WrongColumn) => Err(WrongColumn)
		},
	)?
	Ok({ entities: entities, columns: changed })
}

## `la` with each item replaced by what `fn` makes of it and the item in the
## same row of `lb`.
##
## `List.map2` would say this without a fallback branch, but it always makes a
## new list; this reuses `la` when nothing else holds it. With the lengths
## checked first, the fallback cannot be taken.
zip_with : List(a), List(b), (a, b -> a) -> Try(List(a), Fault)
zip_with = |la, lb, fn| {
	if la.len() != lb.len() {
		return Err(OutOfBounds)
	}
	Ok(
		la.map_with_index(
			|a, row| match lb.get(row) {
				Ok(b) => fn(a, b)
				Err(OutOfBounds) => a
			},
		),
	)
}

zip_with2 : List(a), List(b), List(c), (a, b, c -> a) -> Try(List(a), Fault)
zip_with2 = |la, lb, lc, fn| {
	if la.len() != lb.len() or la.len() != lc.len() {
		return Err(OutOfBounds)
	}
	Ok(
		la.map_with_index(
			|a, row| match (lb.get(row), lc.get(row)) {
				(Ok(b), Ok(c)) => fn(a, b, c)
				_ => a
			},
		),
	)
}

## Where in `arch` the column for `a` is. `fn` is only there to say which
## type `a` is.
plan1 : Archetype(col), (a -> a) -> Try(U64, [Missing]) where [a.Component(col)]
plan1 = |arch, _fn| {
	A : a
	arch.columns.find_first_index(|column| A.from_col(column.data).is_ok()).map_err(|_| Missing)
}

plan_with : Archetype(col), (a, b -> a) -> Try((U64, List(b)), [Missing]) where [a.Component(col), b.Component(col)]
plan_with = |arch, _fn| {
	A : a
	index = arch.columns.find_first_index(|column| A.from_col(column.data).is_ok()).map_err(|_| Missing)?
	lb = fetch(arch)?
	Ok((index, lb))
}

plan_with2 : Archetype(col), (a, b, c -> a) -> Try((U64, List(b), List(c)), [Missing]) where [a.Component(col), b.Component(col), c.Component(col)]
plan_with2 = |arch, _fn| {
	A : a
	index = arch.columns.find_first_index(|column| A.from_col(column.data).is_ok()).map_err(|_| Missing)?
	lb = fetch(arch)?
	lc = fetch(arch)?
	Ok((index, lb, lc))
}

## For maps that write more than one component, the new rows are worked out
## here, from lists the archetype still holds, and `apply` swaps them in. That
## makes new lists, as `List.map2` always does.
plan2 : Archetype(col), (a, b -> (a, b)) -> Try((U64, U64, List((a, b))), [Missing]) where [a.Component(col), b.Component(col)]
plan2 = |arch, fn| {
	A : a
	B : b
	ia = arch.columns.find_first_index(|column| A.from_col(column.data).is_ok()).map_err(|_| Missing)?
	ib = arch.columns.find_first_index(|column| B.from_col(column.data).is_ok()).map_err(|_| Missing)?
	la = fetch(arch)?
	lb = fetch(arch)?
	Ok((ia, ib, List.map2(la, lb, fn)))
}

plan3 : Archetype(col), (a, b, c -> (a, b, c)) -> Try((U64, U64, U64, List((a, b, c))), [Missing]) where [a.Component(col), b.Component(col), c.Component(col)]
plan3 = |arch, fn| {
	A : a
	B : b
	C : c
	ia = arch.columns.find_first_index(|column| A.from_col(column.data).is_ok()).map_err(|_| Missing)?
	ib = arch.columns.find_first_index(|column| B.from_col(column.data).is_ok()).map_err(|_| Missing)?
	ic = arch.columns.find_first_index(|column| C.from_col(column.data).is_ok()).map_err(|_| Missing)?
	la = fetch(arch)?
	lb = fetch(arch)?
	lc = fetch(arch)?
	Ok((ia, ib, ic, List.map3(la, lb, lc, fn)))
}

## The row's cells in the order of `columns`, which is what `append_row` takes.
## It is `ShapeMismatch` unless the two hold exactly the same components.
##
## Nothing is changed here, so a caller can go on to the next archetype after a
## mismatch without having kept a second reference to this one.
line_up : List(Column(col)), Row(col) -> Try(Row(col), [ShapeMismatch])
line_up = |columns, row| {
	if columns.len() != row.len() {
		return Err(ShapeMismatch)
	}
	columns.map_try(|column| row.find_first(|cell| (column.matches)(cell.data)).map_err(|_| ShapeMismatch))
}

## Adds an entity whose row was lined up with this archetype's columns.
append_row : Archetype(col), Ecs.Entity, Row(col) -> Try(Archetype(col), Fault)
append_row = |{ entities, columns }, entity, aligned| {
	var $columns = columns
	var $index = 0
	for cell in aligned {
		$columns = try_update($columns, $index, cell, |column| grow(column, cell))?
		$index = $index + 1
	}
	Ok({ entities: entities.append(entity), columns: $columns })
}

## Removes a row. The archetype's last row is moved into the hole.
drop_row : Archetype(col), U64 -> Try(Archetype(col), Fault)
drop_row = |{ entities, columns }, row| {
	if row >= entities.len() {
		return Err(OutOfBounds)
	}
	var $columns = columns
	var $index = 0
	while $index < $columns.len() {
		spare = spare_at($columns, $index)?
		$columns = try_update($columns, $index, spare, |column| shrink(column, row))?
		$index = $index + 1
	}
	Ok({ entities: entities.drop_swap(row), columns: $columns })
}

## Replaces one component of one row. `index` says which column it is in.
overwrite : Archetype(col), U64, U64, c -> Try(Archetype(col), Fault) where [c.Component(col)]
overwrite = |{ entities, columns }, index, row, component| {
	C : c
	spare = spare_at(columns, index)?
	replaced = try_update(
		columns,
		index,
		spare,
		|column| {
			match C.from_col(column.data) {
				Ok(list) => Ok({ ..column, data: C.to_col(list.set(row, component)?) })
				Err(WrongColumn) => Err(WrongColumn)
			}
		},
	)?
	Ok({ entities: entities, columns: replaced })
}

## A copy of an entity's components, as a row that `place` can put elsewhere.
row_at : List(Archetype(col)), Seat -> Try(Row(col), Fault)
row_at = |archetypes, seat| {
	arch = archetypes.get(seat.arch)?
	Ok(arch.columns.map_try(|column| lone(column, seat.row))?)
}

## The component an entity has, or the inner `MissingComponent` if its
## archetype does not keep that one.
component_at : List(Archetype(col)), Seat -> Try(Try(c, [MissingComponent]), Fault) where [c.Component(col)]
component_at = |archetypes, seat| {
	arch = archetypes.get(seat.arch)?
	found : Try(List(c), [Missing])
	found = fetch(arch)
	match found {
		Ok(list) => {
			component = list.get(seat.row)?
			Ok(Ok(component))
		}
		Err(Missing) => Ok(Err(MissingComponent))
	}
}

## Which column of an archetype holds the same component as `cell`, or the
## inner `NotFound` if none does.
column_index : List(Archetype(col)), U64, Column(col) -> Try(Try(U64, [NotFound]), Fault)
column_index = |archetypes, index, cell| {
	arch = archetypes.get(index)?
	Ok(arch.columns.find_first_index(|column| (cell.matches)(column.data)))
}

## The first archetype holding exactly the components of `row`, the row lined
## up with its columns, and the row number the entity would get there.
find_fit : List(Archetype(col)), Row(col) -> Try({ arch : U64, row : U64, aligned : Row(col) }, [NoFit])
find_fit = |archetypes, row| {
	var $arch = 0
	for candidate in archetypes {
		match line_up(candidate.columns, row) {
			Ok(aligned) => {
				return Ok({ arch: $arch, row: candidate.entities.len(), aligned: aligned })
			}
			Err(ShapeMismatch) => {}
		}
		$arch = $arch + 1
	}
	Err(NoFit)
}

## Puts an entity into the archetype for its components. With no archetype to
## fit into, the row becomes a new one, so there is always somewhere to go.
place : List(Archetype(col)), Ecs.Entity, Row(col) -> Try({ archetypes : List(Archetype(col)), arch : U64, row : U64 }, Fault)
place = |archetypes, entity, row| match find_fit(archetypes, row) {
	Ok(fit) => {
		grown = try_update(archetypes, fit.arch, { entities: [], columns: [] }, |arch| append_row(arch, entity, fit.aligned))?
		Ok({ archetypes: grown, arch: fit.arch, row: fit.row })
	}
	Err(NoFit) => {
		arch = archetypes.len()
		Ok({ archetypes: archetypes.append({ entities: [entity], columns: row }), arch: arch, row: 0 })
	}
}

## Takes a row out of its archetype, and tells the entity that was moved into
## the hole where it is now.
vacate : List(Archetype(col)), List(Slot), Seat -> Try({ archetypes : List(Archetype(col)), slots : List(Slot) }, Fault)
vacate = |archetypes, slots, seat| {
	shrunk = try_update(archetypes, seat.arch, { entities: [], columns: [] }, |arch| drop_row(arch, seat.row))?
	reseated = reseat(slots, shrunk, seat)?
	Ok({ archetypes: shrunk, slots: reseated })
}

## After `drop_row`, the entity at `seat` is the one that used to be last. No
## entity there means the row that was dropped was the last one, and nothing
## moved.
reseat : List(Slot), List(Archetype(col)), Seat -> Try(List(Slot), Fault)
reseat = |slots, archetypes, seat| {
	arch = archetypes.get(seat.arch)?
	match arch.entities.get(seat.row) {
		Ok(moved) => Ok(slots.update(moved.id.to_u64(), |slot| { ..slot, row: seat.row })?)
		Err(OutOfBounds) => Ok(slots)
	}
}

## Writes down where an entity is now. A new id's slot goes on the end.
record_seat : List(Slot), Ecs.Entity, U64, U64 -> Try(List(Slot), Fault)
record_seat = |slots, entity, arch, row| {
	slot = { gen: entity.gen, arch: Live(arch), row: row }
	index = entity.id.to_u64()
	if index == slots.len() {
		Ok(slots.append(slot))
	} else {
		Ok(slots.set(index, slot)?)
	}
}

## The handle for the next entity: the most recently despawned id under its
## next generation, or else a new id.
claim : List(Slot), List(Ecs.Entity) -> Try({ despawned : List(Ecs.Entity), entity : Ecs.Entity }, Fault)
claim = |slots, despawned| match despawned.last() {
	Ok(old) => Ok({ despawned: despawned.drop_last(1), entity: { id: old.id, gen: old.gen + 1 } })
	Err(ListWasEmpty) => {
		id = slots.len().to_u32_try() ? |_| TooManyEntities
		Ok({ despawned: despawned, entity: { id: id, gen: 0 } })
	}
}

locate : List(Slot), Ecs.Entity -> Try(Seat, [NoSuchEntity])
locate = |slots, entity| match slots.get(entity.id.to_u64()) {
	Ok({ gen, arch: Live(arch), row }) if gen == entity.gen => Ok({ gen: gen, arch: arch, row: row })
	_ => Err(NoSuchEntity)
}

spawn_row : List(Archetype(col)), List(Slot), List(Ecs.Entity), Row(col) -> Try({ archetypes : List(Archetype(col)), slots : List(Slot), despawned : List(Ecs.Entity), entity : Ecs.Entity }, Fault)
spawn_row = |archetypes, slots, despawned, row| {
	claimed = claim(slots, despawned)?
	placed = place(archetypes, claimed.entity, row)?
	seated = record_seat(slots, claimed.entity, placed.arch, placed.row)?
	Ok({ archetypes: placed.archetypes, slots: seated, despawned: claimed.despawned, entity: claimed.entity })
}

## The slot keeps its generation: it only changes when the id is handed out
## again, in `claim`.
retire : List(Archetype(col)), List(Slot), List(Ecs.Entity), Ecs.Entity, Seat -> Try({ archetypes : List(Archetype(col)), slots : List(Slot), despawned : List(Ecs.Entity) }, Fault)
retire = |archetypes, slots, despawned, entity, seat| {
	left = vacate(archetypes, slots, seat)?
	row = despawned.len()
	retired = left.slots.update(entity.id.to_u64(), |slot| { ..slot, arch: Despawned, row: row })?
	Ok({ archetypes: left.archetypes, slots: retired, despawned: despawned.append(entity) })
}

## Moves an entity to the archetype for whatever `reshape` makes of its
## components.
migrate : List(Archetype(col)), List(Slot), Ecs.Entity, Seat, (Row(col) -> Row(col)) -> Try({ archetypes : List(Archetype(col)), slots : List(Slot) }, Fault)
migrate = |archetypes, slots, entity, seat, reshape| {
	row = row_at(archetypes, seat)?
	left = vacate(archetypes, slots, seat)?
	placed = place(left.archetypes, entity, reshape(row))?
	seated = record_seat(left.slots, entity, placed.arch, placed.row)?
	Ok({ archetypes: placed.archetypes, slots: seated })
}

## Gives an entity a component: over the one it has, or else by moving it to
## the archetype that also keeps that component.
put : List(Archetype(col)), List(Slot), Ecs.Entity, Seat, c -> Try({ archetypes : List(Archetype(col)), slots : List(Slot) }, Fault) where [c.Component(col)]
put = |archetypes, slots, entity, seat, component| {
	cell = column_of([component])
	match column_index(archetypes, seat.arch, cell)? {
		Ok(index) => {
			replaced = try_update(archetypes, seat.arch, { entities: [], columns: [] }, |arch| overwrite(arch, index, seat.row, component))?
			Ok({ archetypes: replaced, slots: slots })
		}
		Err(NotFound) => migrate(archetypes, slots, entity, seat, |row| row.append(cell))
	}
}

# Tests

Pos := { x : I64, y : I64 }.{
	is_eq : _

	to_col = |list| Positions(list)

	from_col = |col| match col {
		Positions(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Vel := { dx : I64, dy : I64 }.{
	is_eq : _

	to_col = |list| Velocities(list)

	from_col = |col| match col {
		Velocities(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Name := Str.{
	is_eq : _

	to_col = |list| Names(list)

	from_col = |col| match col {
		Names(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Frozen := {}.{
	to_col = |list| Frozens(list)

	from_col = |col| match col {
		Frozens(list) => Ok(list)
		_ => Err(WrongColumn)
	}
}

Tick := I64.{
	from_res = |res| res.tick
}

Title := Str.{
	from_res = |res| res.title
}

pos = |x, y| Pos.({ x: x, y: y })

vel = |dx, dy| Vel.({ dx: dx, dy: dy })

## Three movers (one frozen), one thing that only has a position, one name.
sample = || Ecs.World.empty({})
	.spawn2(pos(0, 0), vel(1, 1))
	.spawn3(pos(10, 10), vel(2, 0), Name.("b"))
	.spawn3(pos(20, 20), vel(5, 5), Frozen.({}))
	.spawn1(pos(99, 99))
	.spawn1(Name.("lonely"))

positions = |world| world.query1().map(|(_, Pos.(p))| (p.x, p.y))

movers = |world| world.query2().map(|(_, Pos.(p), Vel.(v))| (p.x, v.dx)).sort_by(|(x, _)| x)

expect sample().len() == 5

expect positions(sample()) == [(0, 0), (10, 10), (20, 20), (99, 99)]

# A query only sees entities that have every component it asks for.
expect sample().query2().map(|(_, Pos.(p), Vel.(v))| (p.x, v.dx)) == [(0, 1), (10, 2), (20, 5)]

expect sample().query3().map(|(_, Pos.(p), Vel.(v), Name.(n))| (p.x, v.dx, n)) == [(10, 2, "b")]

expect {
	moved = sample().map_with(|Pos.(p), Vel.(v)| Pos.({ x: p.x + v.dx, y: p.y + v.dy }))
	positions(moved) == [(1, 1), (12, 10), (25, 25), (99, 99)]
}

expect {
	swapped = sample().map2(|Pos.(p), Vel.(v)| (Pos.({ x: v.dx, y: v.dy }), Vel.({ dx: p.x, dy: p.y })))
	swapped.query2().map(|(_, Pos.(p), Vel.(v))| (p.x, v.dx)) == [(1, 0), (2, 10), (5, 20)]
}

expect {
	world = sample()
	moved = world.map_with_in(world.select().without(Frozen.to_col), |Pos.(p), Vel.(v)| Pos.({ x: p.x + v.dx, y: p.y + v.dy }))
	positions(moved) == [(1, 1), (12, 10), (20, 20), (99, 99)]
}

expect sample().select().having(Frozen.to_col).query1().map(|(_, Pos.(p))| p.x) == [20]

expect sample().select().without(Vel.to_col).count() == 2

expect {
	Name.(name) = sample().select().without(Pos.to_col).single()?
	name == "lonely"
}

expect {
	found : Try(Name, _)
	found = sample().single()
	found == Err(ManyMatches)
}

expect {
	(world, entity) = sample().spawn(Ecs.Bundle.empty().add(pos(7, 7)).add(Name.("seven")))
	Pos.(p) = world.get(entity)?
	Name.(n) = world.get(entity)?
	missing : Try(Vel, _)
	missing = world.get(entity)
	p.x == 7 and n == "seven" and missing == Err(MissingComponent)
}

# Inserting a new component moves the entity to another archetype and keeps
# what it already had.
expect {
	(world0, entity) = sample().spawn(Ecs.Bundle.empty().add(pos(7, 7)))
	world1 = world0.insert(entity, vel(3, 4))?
	Pos.(p) = world1.get(entity)?
	Vel.(v) = world1.get(entity)?
	p.x == 7 and v.dy == 4 and world1.len() == 6 and movers(world1) == [(0, 1), (7, 3), (10, 2), (20, 5)]
}

# Inserting a component the entity already has replaces it in place.
expect {
	(world0, entity) = sample().spawn(Ecs.Bundle.empty().add(pos(7, 7)))
	world1 = world0.insert(entity, pos(8, 8))?
	positions(world1) == [(0, 0), (10, 10), (20, 20), (99, 99), (8, 8)]
}

expect {
	(world0, entity) = sample().spawn(Ecs.Bundle.empty().add(pos(7, 7)).add(vel(3, 4)))
	(world1, Vel.(taken)) = world0.take(entity)?
	gone : Try(Vel, _)
	gone = world1.get(entity)
	Pos.(kept) = world1.get(entity)?
	taken.dx == 3 and kept.x == 7 and gone == Err(MissingComponent) and world1.len() == 6 and movers(world1) == [(0, 1), (10, 2), (20, 5)]
}

# Despawning from the middle of an archetype moves its last entity into the
# hole, and that entity's handle has to keep working.
expect {
	(world0, first) = Ecs.World.empty({}).spawn(Ecs.Bundle.empty().add(pos(1, 1)))
	(world1, _second) = world0.spawn(Ecs.Bundle.empty().add(pos(2, 2)))
	(world2, third) = world1.spawn(Ecs.Bundle.empty().add(pos(3, 3)))
	world3 = world2.despawn(first)?
	Pos.(p) = world3.get(third)?
	p.x == 3 and positions(world3) == [(3, 3), (2, 2)] and !world3.is_alive(first)
}

# A despawned entity's slot is reused, but old handles to it stay dead.
expect {
	(world0, old) = Ecs.World.empty({}).spawn(Ecs.Bundle.empty().add(pos(1, 1)))
	world1 = world0.despawn(old)?
	(world2, new) = world1.spawn(Ecs.Bundle.empty().add(pos(2, 2)))
	stale : Try(Pos, _)
	stale = world2.get(old)
	new.id == old.id and new != old and stale == Err(NoSuchEntity) and world2.despawn(old).is_err() and world2.len() == 1
}

# Systems run in the order they were added, each seeing the previous one's
# world.
expect {
	step = |world| world.map_with(|Pos.(p), Vel.(v)| Pos.({ x: p.x + v.dx, y: p.y + v.dy }))
	double = |world| world.map1(|Pos.(p)| Pos.({ x: p.x * 2, y: p.y * 2 }))
	world = sample().add_system(step).add_system(double)
	positions(world.update()) == [(2, 2), (24, 20), (50, 50), (198, 198)] and positions(world) == positions(sample())
}

# Despawned entities wait in their own list, generation untouched, and the
# most recently despawned id is the first to be reused.
expect {
	(world0, first) = Ecs.World.empty({}).spawn(Ecs.Bundle.empty().add(pos(1, 1)))
	(world1, second) = world0.spawn(Ecs.Bundle.empty().add(pos(2, 2)))
	world2 = world1.despawn(first)?.despawn(second)?
	(world3, third) = world2.spawn(Ecs.Bundle.empty().add(pos(3, 3)))
	(world4, fourth) = world3.spawn(Ecs.Bundle.empty().add(pos(4, 4)))
	world2.despawned == [first, second] and world2.len() == 0 and world2.despawn(first).is_err()
		and third.id == second.id and third.gen == second.gen + 1
			and fourth.id == first.id and fourth.gen == first.gen + 1
				and world4.despawned == [] and positions(world4) == [(3, 3), (4, 4)]
					and !world4.is_alive(first) and !world4.is_alive(second)
}

expect {
	world = sample().spawn4(pos(1, 2), vel(3, 4), Name.("all"), Frozen.({}))
	found = world.query5().map(|(_, Pos.(p), Vel.(v), Name.(n), Frozen.(_), Pos.(again))| (p.x, v.dy, n, again.y))
	found == [(1, 4, "all", 2)]
}

# A resource is picked by the type the caller expects, and systems can read it.
expect {
	world = Ecs.World.empty({ tick: Tick.(3), title: Title.("demo") })
		.spawn1(pos(1, 1))
		.add_system(
			|w| {
				Tick.(n) = w.resource()
				w.map1(|Pos.(p)| Pos.({ x: p.x + n, y: p.y }))
			},
		)
	Title.(title) = world.resource()
	title == "demo" and positions(world.update()) == [(4, 1)]
}

# Resources are replaced as a whole, so a change keeps the fields it leaves out.
expect {
	world = Ecs.World.empty({ tick: Tick.(3), title: Title.("demo") }).map_resources(|res| { ..res, tick: Tick.(4) })
	Tick.(n) = world.resource()
	Title.(title) = world.resource()
	n == 4 and title == "demo"
}

# The internals say what went wrong instead of handing back what they were
# given.

# A row fits an archetype only if both hold exactly the same components, in
# any order.
expect {
	columns = [column_of([pos(0, 0)]), column_of([vel(1, 1)])]
	swapped = line_up(columns, [column_of([vel(2, 2)]), column_of([pos(3, 3)])])
	fewer = line_up(columns, [column_of([pos(3, 3)])])
	other = line_up(columns, [column_of([pos(3, 3)]), column_of([Name.("n")])])
	swapped.is_ok() and fewer.is_err() and other.is_err()
}

expect {
	grown = grow(column_of([pos(0, 0)]), column_of([vel(1, 1)]))
	match grown {
		Err(WrongColumn) => Bool.True
		_ => Bool.False
	}
}

expect {
	arch = { entities: [{ id: 0, gen: 0 }], columns: [column_of([pos(0, 0)])] }
	match drop_row(arch, 1) {
		Err(OutOfBounds) => Bool.True
		_ => Bool.False
	}
}

expect {
	bumped = try_update([1, 2, 3], 1, 0, |n| Ok(n + 10))
	missing = try_update([1, 2, 3], 3, 0, |n| Ok(n + 10))
	refused : Try(List(I64), [OutOfBounds, Refused])
	refused = try_update([1, 2, 3], 1, 0, |_| Err(Refused))
	bumped == Ok([1, 12, 3]) and missing == Err(OutOfBounds) and refused == Err(Refused)
}

# Taking the only entity out of an archetype leaves the archetype empty, and
# the next entity with those components goes back into it.
expect {
	(world0, entity) = Ecs.World.empty({}).spawn(Ecs.Bundle.empty().add(pos(1, 1)).add(vel(2, 2)))
	(world1, Vel.(_)) = world0.take(entity)?
	world2 = world1.insert(entity, vel(3, 3))?
	Vel.(v) = world2.get(entity)?
	v.dx == 3 and world2.archetypes.len() == 2 and movers(world2) == [(1, 3)]
}

expect {
	world = sample().map_with2(|Pos.(p), Vel.(v), Name.(n)| Pos.({ x: p.x + v.dx + Str.count_utf8_bytes(n).to_i64_wrap(), y: p.y }))
	positions(world) == [(0, 0), (13, 10), (20, 20), (99, 99)]
}

expect {
	world = sample().map3(|Pos.(p), Vel.(v), Name.(n)| (Pos.({ x: v.dx, y: p.y }), Vel.({ dx: p.x, dy: v.dy }), Name.(Str.concat(n, "!"))))
	world.query3().map(|(_, Pos.(p), Vel.(v), Name.(n))| (p.x, v.dx, n)) == [(2, 10, "b!")]
}

expect {
	world = sample()
	frozen = world.map1_in(world.select().having(Frozen.to_col), |Pos.(p)| Pos.({ x: p.x + 1, y: p.y }))
	positions(frozen) == [(0, 0), (10, 10), (21, 20), (99, 99)]
}

# A selection only says which archetypes were kept, so it still works on a
# later version of the world. Archetypes added since are not selected.
expect {
	world0 = sample()
	movers_only = world0.select().having(Vel.to_col)
	world1 = world0.spawn2(pos(50, 50), Frozen.({}))
	world2 = world1.map1_in(movers_only, |Pos.(p)| Pos.({ x: p.x + 1, y: p.y }))
	positions(world2) == [(1, 0), (11, 10), (21, 20), (99, 99), (50, 50)]
}
