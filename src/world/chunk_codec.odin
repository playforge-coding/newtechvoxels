// The chunk byte format, used as-is for the network and for saves. Every
// field from outside is checked before anything is allocated for it.
package world

import "../codec"

CHUNK_FORMAT_VERSION :: 1

Decode_Error :: enum {
	None,
	Truncated,
	Bad_Version,
	Bad_Bits,
	Bad_Palette,
	Bad_Length,
}

// Appends the chunk to `buf`: version, position, index width, palette, data
// words. The data is the chunk's packed form, copied without conversion.
chunk_encode :: proc(c: ^Chunk, buf: ^[dynamic]u8) {
	w := codec.writer(buf)
	codec.put_u8(w, CHUNK_FORMAT_VERSION)
	codec.put_i32(w, c.pos.x)
	codec.put_i32(w, c.pos.y)
	codec.put_i32(w, c.pos.z)
	codec.put_u8(w, c.bits)
	codec.put_u16(w, u16(len(c.palette)))
	for id in c.palette {
		codec.put_u16(w, u16(id))
	}
	codec.put_u32_slice(w, c.data[:])
}

// Reads a chunk written by chunk_encode. On success the chunk owns memory
// from `allocator` and its non-air count is recomputed from the data.
chunk_decode :: proc(data: []u8, allocator := context.allocator) -> (c: Chunk, err: Decode_Error) {
	r := codec.reader(data)
	version, _ := codec.get_u8(&r)
	if r.bad {
		return {}, .Truncated
	}
	if version != CHUNK_FORMAT_VERSION {
		return {}, .Bad_Version
	}
	x, _ := codec.get_i32(&r)
	y, _ := codec.get_i32(&r)
	z, _ := codec.get_i32(&r)
	bits, _ := codec.get_u8(&r)
	count, _ := codec.get_u16(&r)
	if r.bad {
		return {}, .Truncated
	}
	switch bits {
	case 0, 1, 2, 4, 8, 16:
	case:
		return {}, .Bad_Bits
	}
	// The width has to be the one the palette size calls for, so a chunk
	// has one canonical encoding and no width can hide an out-of-range index.
	if count == 0 || int(count) > MAX_PALETTE || bits_for_palette(int(count)) != bits {
		return {}, .Bad_Palette
	}
	// Everything still to read has a known size now; check it before
	// allocating.
	words := words_for_bits(bits)
	if codec.remaining(&r) != int(count) * 2 + 4 + words * 4 {
		return {}, .Bad_Length
	}
	c.pos = Chunk_Pos{x, y, z}
	c.allocator = allocator
	c.bits = bits
	c.palette = make([dynamic]Block_Id, int(count), allocator)
	for i in 0 ..< int(count) {
		v, _ := codec.get_u16(&r)
		c.palette[i] = Block_Id(v)
	}
	n, _ := codec.get_u32(&r)
	if int(n) != words {
		chunk_destroy(&c)
		return {}, .Bad_Length
	}
	c.data = make([dynamic]u32, words, allocator)
	codec.get_u32_into(&r, c.data[:])
	if !codec.finished(&r) {
		chunk_destroy(&c)
		return {}, .Bad_Length
	}
	// Indices past the palette would read out of bounds later, so clamp
	// the check here: any index >= count is a bad chunk.
	if bits != 0 {
		for i in 0 ..< CHUNK_VOLUME {
			if palette_slot(&c, i) >= int(count) {
				chunk_destroy(&c)
				return {}, .Bad_Palette
			}
		}
	}
	chunk_recount(&c)
	c.dirty = true
	return c, .None
}

// The raw palette index of a voxel, for the decoder's range check and the
// mesher's tests.
palette_slot :: proc "contextless" (c: ^Chunk, i: int) -> int {
	if c.bits == 0 {
		return 0
	}
	bit := i * int(c.bits)
	mask := u32(1 << c.bits) - 1
	return int((c.data[bit >> 5] >> u32(bit & 31)) & mask)
}
