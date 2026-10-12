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
		spawn = |world, Bundle.(columns)| {
			(archetypes, index) = find_or_create(world.archetypes, columns)
			target = arch_at(archetypes, index)
			claimed = claim(world.slots, world.despawned, index, target.entities.len())
			filled = {
				entities: target.entities.append(claimed.entity),
				columns: target.columns.map(|column| pull(column, columns, 0)),
			}
			(
				World.({ archetypes: put_arch(archetypes, index, filled), slots: claimed.slots, despawned: claimed.despawned, systems: world.systems, resources: world.resources }),
				claimed.entity,
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
		despawn = |world, entity| {
			slot = locate(world.slots, entity)?
			shrunk = remove_row(arch_at(world.archetypes, slot.arch), slot.row)
			Ok(
				World.(
					{
						archetypes: put_arch(world.archetypes, slot.arch, shrunk),
						slots: retire(reseat(world.slots, shrunk, slot.row), entity, world.despawned.len()),
						despawned: world.despawned.append(entity),
						systems: world.systems,
						resources: world.resources,
					},
				),
			)
		}

		is_alive : World(col, res), Entity -> Bool
		is_alive = |world, entity| locate(world.slots, entity).is_ok()

		## Which component to read is decided by the type the caller expects:
		##
		##     Pos.(pos) = world.get(entity)?
		get : World(col, res), Entity -> Try(c, [NoSuchEntity, MissingComponent]) where [c.Component(col)]
		get = |world, entity| {
			slot = locate(world.slots, entity)?
			list = fetch(arch_at(world.archetypes, slot.arch)) ? |_| MissingComponent
			list.get(slot.row).map_err(|_| MissingComponent)
		}

		## Adds a component to an entity, or replaces the one it already has.
		## Adding moves the entity to the archetype for its new set of
		## components.
		insert : World(col, res), Entity, c -> Try(World(col, res), [NoSuchEntity]) where [c.Component(col)]
		insert = |world, entity, component| {
			slot = locate(world.slots, entity)?
			source = arch_at(world.archetypes, slot.arch)
			match fetch(source) {
				Ok(list) => {
					replaced = store(source, list.set(slot.row, component).ok_or(list))
					Ok(World.({ archetypes: put_arch(world.archetypes, slot.arch, replaced), slots: world.slots, despawned: world.despawned, systems: world.systems, resources: world.resources }))
				}
				Err(_) => {
					column = column_of([component])
					Ok(migrate(world, entity, slot, source.columns.append(column), [column]))
				}
			}
		}

		## Removes a component from an entity and hands it back. As with
		## `get`, the expected type picks the component:
		##
		##     (world2, Stunned.(_)) = world.take(entity)?
		take : World(col, res), Entity -> Try((World(col, res), c), [NoSuchEntity, MissingComponent]) where [c.Component(col)]
		take = |world, entity| {
			C : c
			slot = locate(world.slots, entity)?
			source = arch_at(world.archetypes, slot.arch)
			list = fetch(source) ? |_| MissingComponent
			component = list.get(slot.row) ? |_| MissingComponent
			rest = source.columns.drop_if(|column| C.from_col(column.data).is_ok())
			Ok((migrate(world, entity, slot, rest, []), component))
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

		map1 : World(col, res), (a -> a) -> World(col, res) where [a.Component(col)]
		map1 = |world, fn| world.select().map1(fn).apply_to(world)

		map2 : World(col, res), (a, b -> (a, b)) -> World(col, res) where [a.Component(col), b.Component(col)]
		map2 = |world, fn| world.select().map2(fn).apply_to(world)

		map3 : World(col, res), (a, b, c -> (a, b, c)) -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		map3 = |world, fn| world.select().map3(fn).apply_to(world)

		map_with : World(col, res), (a, b -> a) -> World(col, res) where [a.Component(col), b.Component(col)]
		map_with = |world, fn| world.select().map_with(fn).apply_to(world)

		map_with2 : World(col, res), (a, b, c -> a) -> World(col, res) where [a.Component(col), b.Component(col), c.Component(col)]
		map_with2 = |world, fn| world.select().map_with2(fn).apply_to(world)
	}

	## The archetypes of a world, narrowed to some of them.
	##
	## The components a query or map asks for already narrow it, so `having` is
	## for components you want present but don't need to read, and `without`
	## is for ones that must be absent. Both take a component's `to_col` to
	## say which type they mean:
	##
	##     world.select().without(Frozen.to_col).map_with(|Pos.(p), Vel.(v)| ...).apply_to(world)
	##
	## A selection holds only archetypes, so a map gives back a selection and
	## `apply_to` puts the result into the world it was selected from.
	Selection(col) :: { archetypes : List(Archetype(col)), mask : List(Bool) }.{
		having : Selection(col), (List(c) -> col) -> Selection(col) where [c.Component(col)]
		having = |selection, witness| narrow(selection, |arch| holds(arch, witness))

		without : Selection(col), (List(c) -> col) -> Selection(col) where [c.Component(col)]
		without = |selection, witness| narrow(selection, |arch| !holds(arch, witness))

		## The world with its archetypes replaced by the selection's, including
		## the ones that were narrowed away. `world` has to be the one the
		## selection came from, with nothing spawned or despawned since.
		apply_to : Selection(col), World(col, res) -> World(col, res)
		apply_to = |selection, world| World.(
			{
				archetypes: selection.archetypes,
				slots: world.slots,
				despawned: world.despawned,
				systems: world.systems,
				resources: world.resources,
			},
		)

		## Number of entities in the selected archetypes.
		count : Selection(col) -> U64
		count = |selection| gather(selection, |arch| arch.entities).len()

		query1 : Selection(col) -> List((Entity, a)) where [a.Component(col)]
		query1 = |selection| gather(
			selection,
			|arch| match fetch(arch) {
				Ok(la) => List.map2(arch.entities, la, |entity, a| (entity, a))
				Err(_) => []
			},
		)

		query2 : Selection(col) -> List((Entity, a, b)) where [a.Component(col), b.Component(col)]
		query2 = |selection| gather(
			selection,
			|arch| match (fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb)) => List.map3(arch.entities, la, lb, |entity, a, b| (entity, a, b))
				_ => []
			},
		)

		query3 : Selection(col) -> List((Entity, a, b, c)) where [a.Component(col), b.Component(col), c.Component(col)]
		query3 = |selection| gather(
			selection,
			|arch| match (fetch(arch), fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb), Ok(lc)) => List.map4(arch.entities, la, lb, lc, |entity, a, b, c| (entity, a, b, c))
				_ => []
			},
		)

		query4 : Selection(col) -> List((Entity, a, b, c, d)) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col)]
		query4 = |selection| gather(
			selection,
			|arch| match (fetch(arch), fetch(arch), fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb), Ok(lc), Ok(ld)) => {
					abc = List.map4(arch.entities, la, lb, lc, |entity, a, b, c| (entity, a, b, c))
					List.map2(abc, ld, |(entity, a, b, c), d| (entity, a, b, c, d))
				}
				_ => []
			},
		)

		query5 : Selection(col) -> List((Entity, a, b, c, d, e)) where [a.Component(col), b.Component(col), c.Component(col), d.Component(col), e.Component(col)]
		query5 = |selection| gather(
			selection,
			|arch| match (fetch(arch), fetch(arch), fetch(arch), fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb), Ok(lc), Ok(ld), Ok(le)) => {
					abc = List.map4(arch.entities, la, lb, lc, |entity, a, b, c| (entity, a, b, c))
					List.map3(abc, ld, le, |(entity, a, b, c), d, e| (entity, a, b, c, d, e))
				}
				_ => []
			},
		)

		## The component of the only entity that has one. Handy for
		## resource-like singletons such as a clock.
		single : Selection(col) -> Try(a, [NoMatch, ManyMatches]) where [a.Component(col)]
		single = |selection| {
			found : List(a)
			found = gather(selection, |arch| fetch(arch).ok_or([]))
			if found.len() > 1 {
				Err(ManyMatches)
			} else {
				found.first().map_err(|_| NoMatch)
			}
		}

		map1 : Selection(col), (a -> a) -> Selection(col) where [a.Component(col)]
		map1 = |selection, fn| rewrite(
			selection,
			|arch| match fetch(arch) {
				Ok(la) => store(arch, la.map(fn))
				Err(_) => arch
			},
		)

		## Rewrites two components of every entity that has both.
		map2 : Selection(col), (a, b -> (a, b)) -> Selection(col) where [a.Component(col), b.Component(col)]
		map2 = |selection, fn| rewrite(
			selection,
			|arch| match (fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb)) => {
					out = List.map2(la, lb, fn)
					store(store(arch, out.map(|row| row.0)), out.map(|row| row.1))
				}
				_ => arch
			},
		)

		map3 : Selection(col), (a, b, c -> (a, b, c)) -> Selection(col) where [a.Component(col), b.Component(col), c.Component(col)]
		map3 = |selection, fn| rewrite(
			selection,
			|arch| match (fetch(arch), fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb), Ok(lc)) => {
					out = List.map3(la, lb, lc, fn)
					store(store(store(arch, out.map(|row| row.0)), out.map(|row| row.1)), out.map(|row| row.2))
				}
				_ => arch
			},
		)

		## Rewrites the first component while reading the second: the
		## equivalent of a `(&mut A, &B)` query.
		map_with : Selection(col), (a, b -> a) -> Selection(col) where [a.Component(col), b.Component(col)]
		map_with = |selection, fn| rewrite(
			selection,
			|arch| match (fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb)) => store(arch, List.map2(la, lb, fn))
				_ => arch
			},
		)

		map_with2 : Selection(col), (a, b, c -> a) -> Selection(col) where [a.Component(col), b.Component(col), c.Component(col)]
		map_with2 = |selection, fn| rewrite(
			selection,
			|arch| match (fetch(arch), fetch(arch), fetch(arch)) {
				(Ok(la), Ok(lb), Ok(lc)) => store(arch, List.map3(la, lb, lc, fn))
				_ => arch
			},
		)
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
Column(col) : {
	data : col,
	blank : col,
	matches : col -> Bool,
	drop_swap : col, U64 -> col,
	push_from : col, col, U64 -> col,
}

Archetype(col) : {
	entities : List(Ecs.Entity),
	columns : List(Column(col)),
}

EntityId : U32

Gen : U32

## Index into a world's `archetypes`.
## Where an entity's handle is kept: a row of one of the world's `archetypes`,
## or a row of its `despawned` list.
ArchetypeId : [Despawned, Live(U64)]

Slot : { gen : Gen, arch : ArchetypeId, row : U64 }

## A live entity's slot, with the archetype resolved to an index into
## `archetypes`.
Seat : { gen : Gen, arch : U64, row : U64 }

column_of : List(c) -> Column(col) where [c.Component(col)]
column_of = |items| {
	C : c
	{
		data: C.to_col(items),
		blank: C.to_col([]),
		matches: |other| C.from_col(other).is_ok(),
		drop_swap: |data, row| match C.from_col(data) {
			Ok(list) => C.to_col(list.drop_swap(row))
			Err(_) => data
		},
		push_from: |dst, src, row| match (C.from_col(dst), C.from_col(src)) {
			(Ok(into), Ok(from)) => match from.get(row) {
				Ok(item) => C.to_col(into.append(item))
				Err(_) => dst
			}
			_ => dst
		},
	}
}

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

store : Archetype(col), List(c) -> Archetype(col) where [c.Component(col)]
store = |arch, list| {
	C : c
	{
		entities: arch.entities,
		columns: arch.columns.map(
			|column| if C.from_col(column.data).is_ok() {
				{ ..column, data: C.to_col(list) }
			} else {
				column
			},
		),
	}
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

gather : Ecs.Selection(col), (Archetype(col) -> List(row)) -> List(row)
gather = |selection, rows_of| List.map2(selection.mask, selection.archetypes, |selected, arch| (selected, arch)).fold(
	[],
	|rows, (selected, arch)| if selected rows.concat(rows_of(arch)) else rows,
)

rewrite : Ecs.Selection(col), (Archetype(col) -> Archetype(col)) -> Ecs.Selection(col)
rewrite = |selection, fn| Ecs.Selection.(
	{
		archetypes: List.map2(selection.mask, selection.archetypes, |selected, arch| if selected fn(arch) else arch),
		mask: selection.mask,
	},
)

arch_at : List(Archetype(col)), U64 -> Archetype(col)
arch_at = |archetypes, index| match archetypes.get(index) {
	Ok(arch) => arch
	Err(_) => crash "Ecs: a slot points at an archetype that does not exist"
}

put_arch : List(Archetype(col)), U64, Archetype(col) -> List(Archetype(col))
put_arch = |archetypes, index, arch| archetypes.set(index, arch).ok_or(archetypes)

## The archetype holding exactly the component types in `shape`, added to the
## list if this is the first entity to need it.
find_or_create : List(Archetype(col)), List(Column(col)) -> (List(Archetype(col)), U64)
find_or_create = |archetypes, shape| {
	same_shape = |arch| arch.columns.len() == shape.len() and shape.all(|wanted| arch.columns.any(|column| (wanted.matches)(column.data)))
	match archetypes.find_first_index(same_shape) {
		Ok(index) => (archetypes, index)
		Err(_) => (
			archetypes.append({ entities: [], columns: shape.map(|column| { ..column, data: column.blank }) }),
			archetypes.len(),
		)
	}
}

## Appends to `column` the value at `row` of whichever source column holds the
## same component type.
pull : Column(col), List(Column(col)), U64 -> Column(col)
pull = |column, sources, row| match sources.find_first(|source| (column.matches)(source.data)) {
	Ok(source) => { ..column, data: (column.push_from)(column.data, source.data, row) }
	Err(_) => column
}

remove_row : Archetype(col), U64 -> Archetype(col)
remove_row = |arch, row| {
	entities: arch.entities.drop_swap(row),
	columns: arch.columns.map(|column| { ..column, data: (column.drop_swap)(column.data, row) }),
}

## `drop_swap` fills the hole with the archetype's last entity, so that
## entity's slot has to learn its new row.
reseat : List(Slot), Archetype(col), U64 -> List(Slot)
reseat = |slots, arch, row| match arch.entities.get(row) {
	Ok(moved) => slots.update(moved.id.to_u64(), |slot| { ..slot, row: row }).ok_or(slots)
	Err(_) => slots
}

## The slot keeps its generation: it only changes when the id is handed out
## again, in `claim`.
retire : List(Slot), Ecs.Entity, U64 -> List(Slot)
retire = |slots, entity, row| slots.update(entity.id.to_u64(), |slot| { ..slot, arch: Despawned, row: row }).ok_or(slots)

## Reuses the most recently despawned id, under the next generation, before
## making a new one.
claim : List(Slot), List(Ecs.Entity), U64, U64 -> { slots : List(Slot), despawned : List(Ecs.Entity), entity : Ecs.Entity }
claim = |slots, despawned, arch, row| match despawned.last() {
	Ok(old) => {
		gen = old.gen + 1
		{
			slots: slots.set(old.id.to_u64(), { gen: gen, arch: Live(arch), row: row }).ok_or(slots),
			despawned: despawned.drop_last(1),
			entity: { id: old.id, gen: gen },
		}
	}
	Err(_) => {
		id = slots.len().to_u32_wrap()
		{
			slots: slots.append({ gen: 0, arch: Live(arch), row: row }),
			despawned: despawned,
			entity: { id: id, gen: 0 },
		}
	}
}

locate : List(Slot), Ecs.Entity -> Try(Seat, [NoSuchEntity])
locate = |slots, entity| match slots.get(entity.id.to_u64()) {
	Ok({ gen, arch: Live(arch), row }) if gen == entity.gen => Ok({ gen: gen, arch: arch, row: row })
	_ => Err(NoSuchEntity)
}

## Moves an entity to the archetype for `shape`, carrying over every component
## the two archetypes share and taking the rest from `extra`.
migrate : Ecs.World(col, res), Ecs.Entity, Seat, List(Column(col)), List(Column(col)) -> Ecs.World(col, res)
migrate = |world, entity, slot, shape, extra| {
	source = arch_at(world.archetypes, slot.arch)
	(archetypes, index) = find_or_create(world.archetypes, shape)
	target = arch_at(archetypes, index)
	filled = {
		entities: target.entities.append(entity),
		columns: target.columns.map(|column| pull(pull(column, source.columns, slot.row), extra, 0)),
	}
	shrunk = remove_row(source, slot.row)
	moved = { gen: slot.gen, arch: Live(index), row: target.entities.len() }
	Ecs.World.(
		{
			archetypes: put_arch(put_arch(archetypes, index, filled), slot.arch, shrunk),
			slots: reseat(world.slots, shrunk, slot.row).set(entity.id.to_u64(), moved).ok_or(world.slots),
			despawned: world.despawned,
			systems: world.systems,
			resources: world.resources,
		},
	)
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
	moved = world.select().without(Frozen.to_col).map_with(|Pos.(p), Vel.(v)| Pos.({ x: p.x + v.dx, y: p.y + v.dy })).apply_to(world)
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
