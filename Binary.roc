Binary :: [].{
	# ── entry points ─────────────────────────────────────────────────────────
	encode : a -> List(U8)
		where [a.encoder_for : Format -> (a, EncState -> Try(EncState, []))]
	encode = |value| {
		Shape : a
		encode_shape = Shape.encoder_for(Format.Default)
		Ok(done) = encode_shape(value, { out: List.with_capacity(64) })
		done.out
	}

	decode : List(U8) -> Try(a, [InvalidBinary(Str), ..errs])
		where [a.parser_for : Format -> (State -> Try({ value : a, rest : State }, [InvalidBinary(Str), ..errs]))]
	decode = |bytes| {
		Shape : a
		parse_shape = Shape.parser_for(Format.Default)
		parsed = parse_shape({ bytes, pos: 0, fields: [] })?
		if parsed.rest.pos == bytes.len() Ok(parsed.value) else Err(InvalidBinary("trailing bytes"))
	}

}

## Wire format (all integers little-endian):
##   U8/I8 ... U64/I64   fixed width
##   Bool                1 byte (0/1)
##   F32/F64             IEEE bits, fixed width
##   Str                 varint byte length + UTF-8
##   List                varint count + items
##   Record              field values only, in field-name order (no names, no count)
##   Tuple               items only (arity comes from the type)
##   Nominal (derived)   exactly its backing, so `Id := U32` is 4 bytes
##   Tag                 varint-length tag name + payloads
## Records are positional, so both sides must agree on the type (like bincode).
Format := [Default].{
	rename_field : Format, Str -> Str
	rename_field = |_, name| name

	# ── encoding: primitives ─────────────────────────────────────────────
	encode_u8 : U8, EncState -> Try(EncState, _never_fails)
	encode_u8 = |v, s| Ok({ out: s.out.append(v) })

	encode_bool : Bool, EncState -> Try(EncState, _never_fails)
	encode_bool = |v, s| Ok({ out: s.out.append(if v 1 else 0) })

	encode_u16 : U16, EncState -> Try(EncState, _never_fails)
	encode_u16 = |v, s| Ok(put_le(s, v.to_u64(), 2))

	encode_u32 : U32, EncState -> Try(EncState, _never_fails)
	encode_u32 = |v, s| Ok(put_le(s, v.to_u64(), 4))

	encode_u64 : U64, EncState -> Try(EncState, _never_fails)
	encode_u64 = |v, s| Ok(put_le(s, v, 8))

	encode_i32 : I32, EncState -> Try(EncState, _never_fails)
	encode_i32 = |v, s| Ok(put_le(s, v.to_u64_wrap(), 4))

	encode_i64 : I64, EncState -> Try(EncState, _never_fails)
	encode_i64 = |v, s| Ok(put_le(s, v.to_u64_wrap(), 8))

	encode_f64 : F64, EncState -> Try(EncState, _never_fails)
	encode_f64 = |v, s| Ok(put_le(s, v.to_bits(), 8))

	encode_str : Str, EncState -> Try(EncState, _never_fails)
	encode_str = |v, s| {
		bytes = v.to_utf8()
		Ok({ out: put_varint(s, bytes.len()).out.concat(bytes) })
	}

	## Not part of the builtin protocol: only called by types that opt in
	## (see Bytes below). Same wire shape as a derived List(U8).
	encode_bytes : List(U8), EncState -> Try(EncState, _never_fails)
	encode_bytes = |v, s| Ok({ out: put_varint(s, v.len()).out.concat(v) })

	# ── encoding: containers ─────────────────────────────────────────────
	encode_list : EncState, U64, (Container, (Container, (EncState -> Try(EncState, err)) -> Try(Container, err)) -> Try(Container, err)) -> Try(EncState, err)
	encode_list = |s, count, write_items| {
		started = put_varint(s, count)
		done = write_items({ out: started.out, written: 0 }, write_item)?
		Ok({ out: done.out })
	}

	encode_tuple : EncState, U64, (Container, (Container, (EncState -> Try(EncState, err)) -> Try(Container, err)) -> Try(Container, err)) -> Try(EncState, err)
	encode_tuple = |s, _, write_items| {
		done = write_items({ out: s.out, written: 0 }, write_item)?
		Ok({ out: done.out })
	}

	## Positional: names are dropped. Optional fields that are absent are
	## skipped by the driver, which a positional format can't represent,
	## so records encoded with this format shouldn't use them.
	encode_record : EncState, U64, (Container, (Container, Str, (EncState -> Try(EncState, err)) -> Try(Container, err)) -> Try(Container, err)) -> Try(EncState, err)
	encode_record = |s, _, write_fields| {
		done = write_fields({ out: s.out, written: 0 }, |c, _name, write_value| write_item(c, write_value))?
		Ok({ out: done.out })
	}

	encode_tag : EncState, Str, U64, (Container, (Container, (EncState -> Try(EncState, err)) -> Try(Container, err)) -> Try(Container, err)) -> Try(EncState, err)
	encode_tag = |s, tag, _, write_payloads| {
		named = Format.encode_str(tag, s)?
		done = write_payloads({ out: named.out, written: 0 }, write_item)?
		Ok({ out: done.out })
	}

	# ── parsing: primitives ──────────────────────────────────────────────
	parse_u8 : Format, State -> Try({ value : U8, rest : State }, [InvalidBinary(Str)])
	parse_u8 = |_, st|
		match st.bytes.get(st.pos) {
			Ok(b) => Ok({ value: b, rest: { ..st, pos: st.pos + 1 } })
			Err(_) => Err(eof)
		}

	parse_bool : Format, State -> Try({ value : Bool, rest : State }, [InvalidBinary(Str)])
	parse_bool = |f, st| {
		b = Format.parse_u8(f, st)?
		match b.value {
			0 => Ok({ value: False, rest: b.rest })
			1 => Ok({ value: True, rest: b.rest })
			_ => Err(InvalidBinary("bad bool"))
		}
	}

	parse_u16 : Format, State -> Try({ value : U16, rest : State }, [InvalidBinary(Str)])
	parse_u16 = |_, st| take(st, 2, U16.from_le_bytes(st.bytes, st.pos))

	parse_u32 : Format, State -> Try({ value : U32, rest : State }, [InvalidBinary(Str)])
	parse_u32 = |_, st| take(st, 4, U32.from_le_bytes(st.bytes, st.pos))

	parse_u64 : Format, State -> Try({ value : U64, rest : State }, [InvalidBinary(Str)])
	parse_u64 = |_, st| take(st, 8, U64.from_le_bytes(st.bytes, st.pos))

	parse_i32 : Format, State -> Try({ value : I32, rest : State }, [InvalidBinary(Str)])
	parse_i32 = |_, st| take(st, 4, I32.from_le_bytes(st.bytes, st.pos))

	parse_i64 : Format, State -> Try({ value : I64, rest : State }, [InvalidBinary(Str)])
	parse_i64 = |_, st| take(st, 8, I64.from_le_bytes(st.bytes, st.pos))

	parse_f64 : Format, State -> Try({ value : F64, rest : State }, [InvalidBinary(Str)])
	parse_f64 = |f, st| {
		bits = Format.parse_u64(f, st)?
		Ok({ value: F64.from_bits(bits.value), rest: bits.rest })
	}

	parse_str : Format, State -> Try({ value : Str, rest : State }, [InvalidBinary(Str)])
	parse_str = |_, st| {
		len = take_varint(st)?
		bytes = len.rest.bytes.sublist({ start: len.rest.pos, len: len.value })
		if bytes.len() != len.value {
			return Err(eof)
		}
		match Str.from_utf8(bytes) {
			Ok(value) => Ok({ value, rest: { ..len.rest, pos: len.rest.pos + len.value } })
			Err(_) => Err(InvalidBinary("bad utf-8"))
		}
	}

	parse_bytes : Format, State -> Try({ value : List(U8), rest : State }, [InvalidBinary(Str)])
	parse_bytes = |_, st| {
		len = take_varint(st)?
		value = len.rest.bytes.sublist({ start: len.rest.pos, len: len.value })
		if value.len() != len.value {
			return Err(eof)
		}
		Ok({ value, rest: { ..len.rest, pos: len.rest.pos + len.value } })
	}

	# ── parsing: containers ──────────────────────────────────────────────
	parse_list_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], [InvalidBinary(Str)])
	parse_list_start = |_, st| {
		n = take_varint(st)?
		Ok(Counted({ len: n.value, rest: n.rest }))
	}

	## Never reached: every list is Counted.
	parse_list_next : Format, State -> Try([Item(State), Done(State)], [InvalidBinary(Str)])
	parse_list_next = |_, _| Err(InvalidBinary("unreachable"))

	parse_list_after_item : Format, State -> Try([Continue(State), Done(State)], [InvalidBinary(Str)])
	parse_list_after_item = |_, _| Err(InvalidBinary("unreachable"))

	parse_tuple_start : Format, State, U64 -> Try(State, [InvalidBinary(Str)])
	parse_tuple_start = |_, st, _| Ok(st)

	parse_tuple_next : Format, State, U64, U64 -> Try(State, [InvalidBinary(Str)])
	parse_tuple_next = |_, st, _, _| Ok(st)

	parse_tuple_end : Format, State, U64 -> Try(State, [InvalidBinary(Str)])
	parse_tuple_end = |_, st, _| Ok(st)

	## Uncounted mode: the driver asks for fields one at a time and we hand
	## back the next FieldName by position. `fields` is a stack of "next field
	## index" so nested records each keep their own position.
	parse_record_start : Format, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], [InvalidBinary(Str)])
	parse_record_start = |_, st| Ok(Uncounted({ ..st, fields: st.fields.append(0) }))

	parse_record_field : Format,
	Encoding.FieldName.FieldNames(_shape),
	State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : State }),
			TryField({ name : Str, rest : State }),
			TryFieldCaseless({ name : Str, rest : State }),
			Continue(State),
			Done(State),
		],
		[InvalidBinary(Str)],
	)
	parse_record_field = |_, names, st| {
		index = match st.fields.last() {
			Ok(i) => i
			Err(_) => return Err(InvalidBinary("field outside record"))
		}
		match nth_field(names, index) {
			Ok(field) => Ok(Field({ field, rest: { ..st, fields: st.fields.drop_last(1).append(index + 1) } }))
			Err(_) => Ok(Done({ ..st, fields: st.fields.drop_last(1) }))
		}
	}

	parse_record_after_field : Format, State -> Try([Continue(State), Done(State)], [InvalidBinary(Str)])
	parse_record_after_field = |_, st| Ok(Continue(st))

	skip_record_field : Format, State -> Try(State, [InvalidBinary(Str)])
	skip_record_field = |_, _| Err(InvalidBinary("unreachable: fields are chosen by position"))

	parse_tag_union : Format, Encoding.ParseTagUnionSpec(a), State -> Try({ value : a, rest : State }, [InvalidBinary(Str)])
	parse_tag_union = |f, spec, st| {
		name = Format.parse_str(f, st)?
		Encoding.ParseTagUnionSpec.parse(
			spec,
			{
				tag: name.value,
				encoding: f,
				state: name.rest,
				start_payloads: |s, _| Ok(s),
				next_payload: |s, _, _| Ok(s),
				finish_payloads: |s, _| Ok(s),
				missing: InvalidBinary("unknown tag"),
			},
		)
	}

	invalid_value : Format, State -> [InvalidBinary(Str)]
	invalid_value = |_, _| InvalidBinary("invalid value")
}

State : { bytes : List(U8), pos : U64, fields : List(U64) }

EncState : { out : List(U8) }

Container : { out : List(U8), written : U64 }

eof = InvalidBinary("unexpected end of input")

put_le : EncState, U64, U8 -> EncState
put_le = |s, v, n|
	match v.append_le_bytes_to(s.out, n) {
		Ok(bytes) => { out: bytes }
		Err(_) => s
	}

patch_le : List(U8), U64, U64 -> List(U8)
patch_le = |out, at, v|
	match v.append_le_bytes_to(out.take_first(at), 8) {
		Ok(head) => head.concat(out.drop_first(at + 8))
		Err(_) => out
	}

## LEB128: 7 bits per byte, high bit set means "more follows". Lengths
## under 128 cost one byte.
put_varint : EncState, U64 -> EncState
put_varint = |s, v| {
	var $out = s.out
	var $v = v
	while $v >= 0x80 {
		$out = $out.append($v.bitwise_and(0x7F).bitwise_or(0x80).to_u8_wrap())
		$v = $v.shr_zf_wrap(7)
	}
	{ out: $out.append($v.to_u8_wrap()) }
}

take_varint : State -> Try({ value : U64, rest : State }, [InvalidBinary(Str)])
take_varint = |st| {
	var $value = 0.U64
	var $shift = 0.U8
	var $pos = st.pos
	while True {
		b = match st.bytes.get($pos) {
			Ok(byte) => byte
			Err(_) => return Err(eof)
		}
		if $shift > 63 {
			return Err(InvalidBinary("varint too long"))
		}
		$value = $value.bitwise_or(b.bitwise_and(0x7F).to_u64().shl_wrap($shift))
		$pos = $pos + 1
		if b < 0x80 {
			return Ok({ value: $value, rest: { ..st, pos: $pos } })
		}
		$shift = $shift + 7
	}
	Err(eof)
}

nth_field : Encoding.FieldName.FieldNames(_shape), U64 -> Try(Encoding.FieldName(_shape), [NotFound])
nth_field = |names, n| {
	var $rest = Encoding.FieldName.FieldNames.iter(names).drop_first(n)
	while True {
		match Iter.next($rest) {
			One({ item, rest: _ }) => return Ok(item)
			Skip({ rest }) => {
				$rest = rest
			}
			Done => return Err(NotFound)
		}
	}
	Err(NotFound)
}

take : State, U64, Try(a, [OutOfBounds]) -> Try({ value : a, rest : State }, [InvalidBinary(Str)])
take = |st, n, read|
	match read {
		Ok(value) => Ok({ value, rest: { ..st, pos: st.pos + n } })
		Err(_) => Err(eof)
	}

write_item : Container, (EncState -> Try(EncState, err)) -> Try(Container, err)
write_item = |c, write_value| {
	encoded = write_value({ out: c.out })?
	Ok({ out: encoded.out, written: c.written + 1 })
}

# ── custom types ─────────────────────────────────────────────────────────

## Opt into the derived codec: same wire shape as the backing record.
Point := { x : I64, y : I64 }.{
	parser_for : _
	encoder_for : _
}

## Hand-written codec: one byte instead of a length-prefixed tag name.
Color := [Red, Green, Blue].{
	encoder_for : encoding -> (Color, state -> Try(state, err))
		where [encoding.encode_u8 : U8, state -> Try(state, err)]
	encoder_for = |_| {
		Enc : encoding
		|color, state| Enc.encode_u8(
			match color {
				Red => 0
				Green => 1
				Blue => 2
			},
			state,
		)
	}

	parser_for : encoding -> (state -> Try({ value : Color, rest : state }, [InvalidBinary(Str)]))
		where [encoding.parse_u8 : encoding, state -> Try({ value : U8, rest : state }, [InvalidBinary(Str)])]
	parser_for = |encoding| {
		Enc : encoding
		|state| {
			b = Enc.parse_u8(encoding, state)?
			match b.value {
				0 => Ok({ value: Red, rest: b.rest })
				1 => Ok({ value: Green, rest: b.rest })
				2 => Ok({ value: Blue, rest: b.rest })
				_ => Err(InvalidBinary("bad Color"))
			}
		}
	}
}

## Bulk byte blob: one concat instead of one encode_u8 call per byte.
## (Nesting a List-backed nominal like this in a derived record hung the
## compiler on nightlies up to 09-25, roc-lang/roc#11727; fine on 09-29.)
Bytes := List(U8).{
	encoder_for : encoding -> (Bytes, state -> Try(state, err))
		where [encoding.encode_bytes : List(U8), state -> Try(state, err)]
	encoder_for = |_| {
		Enc : encoding
		|Bytes.(bytes), state| Enc.encode_bytes(bytes, state)
	}

	parser_for : encoding -> (state -> Try({ value : Bytes, rest : state }, err))
		where [encoding.parse_bytes : encoding, state -> Try({ value : List(U8), rest : state }, err)]
	parser_for = |encoding| {
		Enc : encoding
		|state| {
			parsed = Enc.parse_bytes(encoding, state)?
			Ok({ value: Bytes.(parsed.value), rest: parsed.rest })
		}
	}
}

# ── tests ────────────────────────────────────────────────────────────────
expect Binary.encode(258.U16) == [2, 1]
expect Binary.encode("hi") == [2, 104, 105]
expect Binary.encode([1.U8, 2, 3]) == [3, 1, 2, 3]

expect {
	bytes = Binary.encode({ name: "Sam", age: 30.U32 })
	back : Try({ name : Str, age : U32 }, _)
	back = Binary.decode(bytes)
	back == Ok({ name: "Sam", age: 30 })
}

expect {
	v : List([Circle(F64), Rect(U32, U32), Empty])
	v = [Circle(1.5), Rect(2, 3), Empty]
	back : Try(List([Circle(F64), Rect(U32, U32), Empty]), _)
	back = Binary.decode(Binary.encode(v))
	back == Ok(v)
}

expect {
	back : Try((Str, I64, Bool), _)
	back = Binary.decode(Binary.encode(("x", -5.I64, Bool.True)))
	back == Ok(("x", -5, True))
}

expect Binary.encode(Bool.True) == [1]
expect Binary.encode(-5.I64) == [251, 255, 255, 255, 255, 255, 255, 255]
expect Binary.encode(("x", 7.U8)) == [1, 120, 7]
expect {
	back : Try(Bool, _)
	back = Binary.decode([1])
	back == Ok(True)
}
expect {
	back : Try((Str, U8), _)
	back = Binary.decode(Binary.encode(("x", 7.U8)))
	back == Ok(("x", 7))
}
expect {
	back : Try(I64, _)
	back = Binary.decode(Binary.encode(-5.I64))
	back == Ok(-5)
}

# expect {
# 	v = { at: Point.{ x: 1, y: -2 }, color: Color.Blue, img: Bytes.([9, 8, 7]) }
# 	back : Try({ at : Point, color : Color, img : Bytes }, _)
# 	back = Binary.decode(Binary.encode(v))
# 	match back {
# 		Ok({ at, color: Blue, img: Bytes.(img) }) => at.x == 1 and at.y == -2 and img == [9, 8, 7]
# 		_ => False
# 	}
# }

# Bytes and a derived List(U8) share a wire shape.
expect Binary.encode(Bytes.([1, 2])) == Binary.encode([1.U8, 2])

# ── metadata-free wrappers ─────────────────────────────────────────────

UserId := U32.{
	parser_for : _
	encoder_for : _
}

# A derived nominal wrapper is exactly its backing.
expect Binary.encode(UserId.(7)) == [7, 0, 0, 0]

# So is a single-field record: no name, no count.
expect Binary.encode({ id: 7.U32 }) == [7, 0, 0, 0]

# Field order is by name (a, b), independent of how the literal is written.
expect Binary.encode({ b: 2.U8, a: 1.U8 }) == [1, 2]

expect {
	v = { owner: UserId.(7), inner: { z: 1.U8, a: "x" }, tail: 3.U16 }
	back : Try({ owner : UserId, inner : { z : U8, a : Str }, tail : U16 }, _)
	back = Binary.decode(Binary.encode(v))
	match back {
		Ok({ owner: UserId.(id), inner, tail }) => id == 7 and inner.z == 1 and inner.a == "x" and tail == 3
		_ => False
	}
}

expect {
	back : Try(List({ a : U8, b : U8 }), _)
	back = Binary.decode(Binary.encode([{ a: 1.U8, b: 2.U8 }, { a: 3, b: 4 }]))
	back == Ok([{ a: 1, b: 2 }, { a: 3, b: 4 }])
}

expect {
	long = Str.repeat("a", 300)
	back : Try(Str, _)
	back = Binary.decode(Binary.encode(long))
	back == Ok(long) and Binary.encode(long).take_first(2) == [0xAC, 0x02]
}
