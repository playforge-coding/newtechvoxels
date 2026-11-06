// Bounds-checked little-endian byte reading and writing, shared by every
// format in the game (chunks, messages, save files). A reader never reads
// past its input: every get reports failure instead, and decoders turn that
// into an error. Nothing here allocates.
package codec

Writer :: struct {
	buf: ^[dynamic]u8,
}

Reader :: struct {
	data: []u8,
	pos:  int,
	// Set once any read fails; later reads keep failing and return zero.
	bad:  bool,
}

writer :: proc(buf: ^[dynamic]u8) -> Writer {
	return Writer{buf = buf}
}

reader :: proc(data: []u8) -> Reader {
	return Reader{data = data}
}

put_u8 :: proc(w: Writer, v: u8) {
	append(w.buf, v)
}

put_u16 :: proc(w: Writer, v: u16) {
	append(w.buf, u8(v), u8(v >> 8))
}

put_u32 :: proc(w: Writer, v: u32) {
	append(w.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

put_u64 :: proc(w: Writer, v: u64) {
	put_u32(w, u32(v))
	put_u32(w, u32(v >> 32))
}

put_i32 :: proc(w: Writer, v: i32) {
	put_u32(w, u32(v))
}

put_f32 :: proc(w: Writer, v: f32) {
	put_u32(w, transmute(u32)v)
}

put_bool :: proc(w: Writer, v: bool) {
	put_u8(w, v ? 1 : 0)
}

// A length-prefixed byte string. The length is a u32.
put_bytes :: proc(w: Writer, v: []u8) {
	put_u32(w, u32(len(v)))
	append(w.buf, ..v)
}

put_string :: proc(w: Writer, v: string) {
	put_bytes(w, transmute([]u8)v)
}

put_u32_slice :: proc(w: Writer, v: []u32) {
	put_u32(w, u32(len(v)))
	for x in v {
		put_u32(w, x)
	}
}

remaining :: proc(r: ^Reader) -> int {
	return len(r.data) - r.pos
}

// True when every read succeeded and nothing is left over.
finished :: proc(r: ^Reader) -> bool {
	return !r.bad && r.pos == len(r.data)
}

@(private = "file")
take :: proc(r: ^Reader, n: int) -> ([]u8, bool) {
	if r.bad || n < 0 || n > remaining(r) {
		r.bad = true
		return nil, false
	}
	s := r.data[r.pos:r.pos + n]
	r.pos += n
	return s, true
}

get_u8 :: proc(r: ^Reader) -> (u8, bool) {
	b, ok := take(r, 1)
	if !ok {
		return 0, false
	}
	return b[0], true
}

get_u16 :: proc(r: ^Reader) -> (u16, bool) {
	b, ok := take(r, 2)
	if !ok {
		return 0, false
	}
	return u16(b[0]) | u16(b[1]) << 8, true
}

get_u32 :: proc(r: ^Reader) -> (u32, bool) {
	b, ok := take(r, 4)
	if !ok {
		return 0, false
	}
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24, true
}

get_u64 :: proc(r: ^Reader) -> (u64, bool) {
	lo, ok1 := get_u32(r)
	hi, ok2 := get_u32(r)
	return u64(lo) | u64(hi) << 32, ok1 && ok2
}

get_i32 :: proc(r: ^Reader) -> (i32, bool) {
	v, ok := get_u32(r)
	return i32(v), ok
}

get_f32 :: proc(r: ^Reader) -> (f32, bool) {
	v, ok := get_u32(r)
	return transmute(f32)v, ok
}

get_bool :: proc(r: ^Reader) -> (bool, bool) {
	v, ok := get_u8(r)
	return v != 0, ok
}

// A length-prefixed byte string, at most `limit` bytes. The slice points
// into the reader's data, so copy it if it has to outlive the input.
get_bytes :: proc(r: ^Reader, limit: int) -> ([]u8, bool) {
	n, ok := get_u32(r)
	if !ok || int(n) > limit {
		r.bad = true
		return nil, false
	}
	return take(r, int(n))
}

get_string :: proc(r: ^Reader, limit: int) -> (string, bool) {
	b, ok := get_bytes(r, limit)
	return string(b), ok
}

// Reads a u32 count and then that many u32s into `out`, which has to be
// sized by the caller from a count it already checked.
get_u32_into :: proc(r: ^Reader, out: []u32) -> bool {
	for i in 0 ..< len(out) {
		v, ok := get_u32(r)
		if !ok {
			return false
		}
		out[i] = v
	}
	return true
}
