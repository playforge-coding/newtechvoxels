// Chunks: a cube of voxels stored as a palette of block ids plus packed
// palette indices. The same packed form is what goes to the GPU, over the
// network and to disk, so a chunk is never re-encoded between them.
package world

import "base:intrinsics"
import "core:mem"

// Voxels per chunk edge. The data formats depend on it, so it's a constant.
CHUNK_SIZE :: 32
CHUNK_AREA :: CHUNK_SIZE * CHUNK_SIZE
CHUNK_VOLUME :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

// A block id is global and the same on every machine of a session; the
// registry maps it to a definition. 0 is always air.
Block_Id :: distinct u16
AIR :: Block_Id(0)

// The most entries a palette may hold. 16-bit indices would allow more,
// but a chunk with that many distinct blocks is data from a broken or
// hostile source, not a world.
MAX_PALETTE :: 4096

// Position of a chunk in the chunk grid.
Chunk_Pos :: distinct [3]i32
// Position of a block in the world.
Block_Pos :: distinct [3]i32

Chunk :: struct {
	pos:       Chunk_Pos,
	// Palette index to block id. Entry 0 is whatever the chunk was filled
	// with (air for an empty one), so a fresh chunk needs no data words.
	palette:   [dynamic]Block_Id,
	// Bits per palette index: 0, 1, 2, 4, 8 or 16. Indices never straddle
	// a 32-bit word, and 0 bits means the whole chunk is palette[0].
	bits:      u8,
	// Packed indices, voxel i at word (i*bits)/32, shift (i*bits)%32.
	data:      [dynamic]u32,
	// Count of voxels that aren't AIR, kept up to date by chunk_set.
	non_air:   u32,
	// Set by chunk_set; the renderer and the storage clear it when they
	// have consumed the change.
	dirty:     bool,
	allocator: mem.Allocator,
}

// The linear index of a voxel. y is up, and x varies fastest.
voxel_index :: #force_inline proc "contextless" (x, y, z: int) -> int {
	return (y * CHUNK_SIZE + z) * CHUNK_SIZE + x
}

in_chunk :: #force_inline proc "contextless" (x, y, z: int) -> bool {
	return (x | y | z) >= 0 && x < CHUNK_SIZE && y < CHUNK_SIZE && z < CHUNK_SIZE
}

// Words needed for CHUNK_VOLUME indices of the given width.
words_for_bits :: proc "contextless" (bits: u8) -> int {
	return CHUNK_VOLUME * int(bits) / 32
}

// The smallest valid index width that can address `entries` palette entries.
bits_for_palette :: proc "contextless" (entries: int) -> u8 {
	switch {
	case entries <= 1:
		return 0
	case entries <= 2:
		return 1
	case entries <= 4:
		return 2
	case entries <= 16:
		return 4
	case entries <= 256:
		return 8
	}
	return 16
}

// Makes a chunk filled with one block. Its memory comes from `allocator`.
chunk_init :: proc(c: ^Chunk, pos: Chunk_Pos, fill := AIR, allocator := context.allocator) {
	c.pos = pos
	c.allocator = allocator
	c.palette = make([dynamic]Block_Id, 1, 8, allocator)
	c.palette[0] = fill
	c.bits = 0
	c.data = make([dynamic]u32, 0, 0, allocator)
	c.non_air = fill == AIR ? 0 : CHUNK_VOLUME
	c.dirty = true
}

chunk_destroy :: proc(c: ^Chunk) {
	delete(c.palette)
	delete(c.data)
	c^ = {}
}

// Copies a chunk, including its allocator.
chunk_clone :: proc(c: ^Chunk, allocator := context.allocator) -> Chunk {
	r := c^
	r.allocator = allocator
	r.palette = make([dynamic]Block_Id, len(c.palette), cap(c.palette), allocator)
	copy(r.palette[:], c.palette[:])
	r.data = make([dynamic]u32, len(c.data), max(len(c.data), 1), allocator)
	copy(r.data[:], c.data[:])
	return r
}

chunk_is_empty :: proc "contextless" (c: ^Chunk) -> bool {
	return c.non_air == 0
}

chunk_is_full :: proc "contextless" (c: ^Chunk) -> bool {
	return c.non_air == CHUNK_VOLUME
}

@(private = "file")
read_index :: #force_inline proc "contextless" (c: ^Chunk, i: int) -> int {
	if c.bits == 0 {
		return 0
	}
	bit := i * int(c.bits)
	word := c.data[bit >> 5]
	shift := u32(bit & 31)
	mask := u32(1 << c.bits) - 1
	return int((word >> shift) & mask)
}

@(private = "file")
write_index :: #force_inline proc "contextless" (c: ^Chunk, i: int, index: int) {
	bit := i * int(c.bits)
	shift := u32(bit & 31)
	mask := u32(1 << c.bits) - 1
	w := &c.data[bit >> 5]
	w^ = (w^ & ~(mask << shift)) | (u32(index) << shift)
}

// The block at a voxel. Coordinates must be inside the chunk.
chunk_get :: proc "contextless" (c: ^Chunk, x, y, z: int) -> Block_Id {
	return c.palette[read_index(c, voxel_index(x, y, z))]
}

chunk_get_index :: proc "contextless" (c: ^Chunk, i: int) -> Block_Id {
	return c.palette[read_index(c, i)]
}

// Sets a voxel, growing the palette and widening the indices when needed.
// Returns whether the voxel changed.
chunk_set :: proc(c: ^Chunk, x, y, z: int, id: Block_Id) -> bool {
	i := voxel_index(x, y, z)
	old := c.palette[read_index(c, i)]
	if old == id {
		return false
	}
	index := palette_index(c, id)
	if index < 0 {
		index = palette_add(c, id)
	}
	write_index(c, i, index)
	if old == AIR {
		c.non_air += 1
	} else if id == AIR {
		c.non_air -= 1
	}
	c.dirty = true
	return true
}

// Fills the whole chunk with one block, resetting the palette.
chunk_fill :: proc(c: ^Chunk, id: Block_Id) {
	clear(&c.palette)
	append(&c.palette, id)
	clear(&c.data)
	c.bits = 0
	c.non_air = id == AIR ? 0 : CHUNK_VOLUME
	c.dirty = true
}

// The palette index of a block, or -1 when the palette doesn't hold it.
palette_index :: proc "contextless" (c: ^Chunk, id: Block_Id) -> int {
	for p, i in c.palette {
		if p == id {
			return i
		}
	}
	return -1
}

// Adds a block to the palette and repacks the indices if they got wider.
// Returns the new entry's index.
@(private = "file")
palette_add :: proc(c: ^Chunk, id: Block_Id) -> int {
	append(&c.palette, id)
	index := len(c.palette) - 1
	needed := bits_for_palette(len(c.palette))
	if needed != c.bits {
		repack(c, needed)
	}
	return index
}

// Rewrites the data words at a new index width.
@(private = "file")
repack :: proc(c: ^Chunk, bits: u8) {
	old := c^
	c.bits = bits
	c.data = make([dynamic]u32, words_for_bits(bits), c.allocator)
	if old.bits != 0 {
		for i in 0 ..< CHUNK_VOLUME {
			write_index(c, i, read_index(&old, i))
		}
	}
	delete(old.data)
}

// Rebuilds the palette with only the blocks the chunk still uses and the
// narrowest indices for them. Call it before saving or sending, not on
// every edit.
chunk_compact :: proc(c: ^Chunk) {
	used := make([]u32, len(c.palette), context.temp_allocator)
	for i in 0 ..< CHUNK_VOLUME {
		used[read_index(c, i)] += 1
	}
	remap := make([]int, len(c.palette), context.temp_allocator)
	new_palette := make([dynamic]Block_Id, 0, len(c.palette), c.allocator)
	for count, i in used {
		if count > 0 {
			remap[i] = len(new_palette)
			append(&new_palette, c.palette[i])
		}
	}
	bits := bits_for_palette(len(new_palette))
	new_data := make([dynamic]u32, words_for_bits(bits), c.allocator)
	fresh := Chunk {
		palette = new_palette,
		bits    = bits,
		data    = new_data,
	}
	if bits != 0 {
		for i in 0 ..< CHUNK_VOLUME {
			write_index(&fresh, i, remap[read_index(c, i)])
		}
	}
	delete(c.palette)
	delete(c.data)
	c.palette = new_palette
	c.bits = bits
	c.data = new_data
}

// Recounts non-air voxels from the data; the codec uses it after decoding
// so the count can't be lied about.
chunk_recount :: proc "contextless" (c: ^Chunk) {
	counts: [MAX_PALETTE]u32
	for i in 0 ..< CHUNK_VOLUME {
		counts[read_index(c, i)] += 1
	}
	n: u32
	for id, i in c.palette {
		if id != AIR {
			n += counts[i]
		}
	}
	c.non_air = n
}

// Splits a world block position into its chunk and the voxel inside it.
split_block_pos :: proc "contextless" (p: Block_Pos) -> (chunk: Chunk_Pos, x, y, z: int) {
	chunk = Chunk_Pos{floor_div(p.x), floor_div(p.y), floor_div(p.z)}
	x = int(p.x - chunk.x * CHUNK_SIZE)
	y = int(p.y - chunk.y * CHUNK_SIZE)
	z = int(p.z - chunk.z * CHUNK_SIZE)
	return
}

@(private = "file")
floor_div :: #force_inline proc "contextless" (v: i32) -> i32 {
	return v >> intrinsics.constant_log2(CHUNK_SIZE)
}

chunk_origin :: proc "contextless" (p: Chunk_Pos) -> Block_Pos {
	return Block_Pos{p.x * CHUNK_SIZE, p.y * CHUNK_SIZE, p.z * CHUNK_SIZE}
}
