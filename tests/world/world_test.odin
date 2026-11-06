package test_world

import "core:hash"
import "core:testing"

import "../../src/world"

STONE :: world.Block_Id(world.Builtin.Stone)
DIRT :: world.Block_Id(world.Builtin.Dirt)
GRASS :: world.Block_Id(world.Builtin.Grass)

@(test)
palette_widens_and_reads_back :: proc(t: ^testing.T) {
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	defer world.chunk_destroy(&c)

	testing.expect_value(t, c.bits, u8(0))
	testing.expect(t, world.chunk_is_empty(&c))

	// Two entries fit one bit, then widths grow at 3, 5 and 17 entries.
	testing.expect(t, world.chunk_set(&c, 1, 2, 3, STONE))
	testing.expect_value(t, c.bits, u8(1))
	testing.expect_value(t, world.chunk_get(&c, 1, 2, 3), STONE)
	testing.expect_value(t, world.chunk_get(&c, 0, 0, 0), world.AIR)
	testing.expect_value(t, c.non_air, u32(1))

	world.chunk_set(&c, 0, 0, 0, DIRT)
	testing.expect_value(t, c.bits, u8(2))
	world.chunk_set(&c, 5, 5, 5, GRASS)
	world.chunk_set(&c, 6, 6, 6, world.Block_Id(100))
	testing.expect_value(t, c.bits, u8(4))
	for i in 0 ..< 20 {
		world.chunk_set(&c, i, 31, 31, world.Block_Id(200 + i))
	}
	testing.expect_value(t, c.bits, u8(8))
	// Everything written before the widening is still there.
	testing.expect_value(t, world.chunk_get(&c, 1, 2, 3), STONE)
	testing.expect_value(t, world.chunk_get(&c, 0, 0, 0), DIRT)
	testing.expect_value(t, world.chunk_get(&c, 5, 5, 5), GRASS)
	testing.expect_value(t, world.chunk_get(&c, 6, 6, 6), world.Block_Id(100))
	testing.expect_value(t, world.chunk_get(&c, 19, 31, 31), world.Block_Id(219))
	testing.expect_value(t, c.non_air, u32(24))

	// Setting the same value again changes nothing.
	testing.expect(t, !world.chunk_set(&c, 1, 2, 3, STONE))
	// Clearing a voxel counts down.
	testing.expect(t, world.chunk_set(&c, 1, 2, 3, world.AIR))
	testing.expect_value(t, c.non_air, u32(23))
}

@(test)
compact_drops_unused_entries :: proc(t: ^testing.T) {
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	defer world.chunk_destroy(&c)
	for i in 0 ..< 20 {
		world.chunk_set(&c, i, 0, 0, world.Block_Id(10 + i))
	}
	for i in 1 ..< 20 {
		world.chunk_set(&c, i, 0, 0, world.AIR)
	}
	testing.expect_value(t, c.bits, u8(8))
	world.chunk_compact(&c)
	testing.expect_value(t, len(c.palette), 2)
	testing.expect_value(t, c.bits, u8(1))
	testing.expect_value(t, world.chunk_get(&c, 0, 0, 0), world.Block_Id(10))
	testing.expect_value(t, world.chunk_get(&c, 1, 0, 0), world.AIR)
	testing.expect_value(t, c.non_air, u32(1))
}

@(test)
codec_round_trips :: proc(t: ^testing.T) {
	c: world.Chunk
	world.chunk_init(&c, {3, -2, 7})
	defer world.chunk_destroy(&c)
	for i in 0 ..< 500 {
		world.chunk_set(&c, i % 32, (i / 32) % 32, i % 7, world.Block_Id(1 + i % 5))
	}
	buf: [dynamic]u8
	defer delete(buf)
	world.chunk_encode(&c, &buf)

	d, err := world.chunk_decode(buf[:])
	defer world.chunk_destroy(&d)
	testing.expect_value(t, err, world.Decode_Error.None)
	testing.expect_value(t, d.pos, world.Chunk_Pos{3, -2, 7})
	testing.expect_value(t, d.bits, c.bits)
	testing.expect_value(t, d.non_air, c.non_air)
	for i in 0 ..< world.CHUNK_VOLUME {
		if world.chunk_get_index(&d, i) != world.chunk_get_index(&c, i) {
			testing.fail_now(t, "voxel differs after decode")
		}
	}
	// Encoding again gives the same bytes: the format is canonical.
	again: [dynamic]u8
	defer delete(again)
	world.chunk_encode(&d, &again)
	testing.expect(t, len(again) == len(buf) && string(again[:]) == string(buf[:]))
}

@(test)
codec_rejects_bad_input :: proc(t: ^testing.T) {
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	defer world.chunk_destroy(&c)
	world.chunk_set(&c, 0, 0, 0, STONE)
	world.chunk_set(&c, 1, 0, 0, DIRT)
	buf: [dynamic]u8
	defer delete(buf)
	world.chunk_encode(&c, &buf)

	// Every truncation fails cleanly.
	for n in 0 ..< len(buf) {
		_, err := world.chunk_decode(buf[:n])
		if err == .None {
			testing.fail_now(t, "truncated chunk decoded")
		}
	}
	// A trailing byte fails too.
	append(&buf, 0)
	_, err := world.chunk_decode(buf[:])
	testing.expect_value(t, err, world.Decode_Error.Bad_Length)
	pop(&buf)

	// Wrong version, bad index width, and a palette count that doesn't
	// match the width.
	bad := make([]u8, len(buf))
	defer delete(bad)
	copy(bad, buf[:])
	bad[0] = 99
	_, err = world.chunk_decode(bad)
	testing.expect_value(t, err, world.Decode_Error.Bad_Version)
	copy(bad, buf[:])
	bad[13] = 3
	_, err = world.chunk_decode(bad)
	testing.expect_value(t, err, world.Decode_Error.Bad_Bits)
	copy(bad, buf[:])
	bad[14] = 200
	_, err = world.chunk_decode(bad)
	testing.expect_value(t, err, world.Decode_Error.Bad_Palette)

	// An index past the palette (the chunk has 3 entries at 2 bits, so
	// index 3 is out of range) is caught.
	copy(bad, buf[:])
	bad[len(bad) - 4] = 0xFF
	_, err = world.chunk_decode(bad)
	testing.expect_value(t, err, world.Decode_Error.Bad_Palette)

	// Garbage never crashes.
	_, err = world.chunk_decode(
		[]u8{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0xFF, 0xFF, 0, 0, 0, 0},
	)
	testing.expect(t, err != .None)
}

@(test)
split_block_pos_handles_negatives :: proc(t: ^testing.T) {
	cp, x, y, z := world.split_block_pos({-1, 32, 63})
	testing.expect_value(t, cp, world.Chunk_Pos{-1, 1, 1})
	testing.expect_value(t, x, 31)
	testing.expect_value(t, y, 0)
	testing.expect_value(t, z, 31)
	cp, x, _, _ = world.split_block_pos({-33, 0, 0})
	testing.expect_value(t, cp.x, i32(-2))
	testing.expect_value(t, x, 31)
}

@(test)
generation_is_deterministic :: proc(t: ^testing.T) {
	// The hash of a generated chunk's bytes, pinned here. If generation
	// changes on purpose, update the value and say so in the commit.
	terrain := world.Terrain {
		params = world.DEFAULT_TERRAIN,
	}
	gen := world.terrain_generator(&terrain)
	buf: [dynamic]u8
	defer delete(buf)
	for pos in ([]world.Chunk_Pos{{0, 0, 0}, {-3, 1, 5}, {7, 2, -2}}) {
		c: world.Chunk
		world.chunk_init(&c, pos)
		gen.generate(gen.data, &c)
		world.chunk_compact(&c)
		clear(&buf)
		world.chunk_encode(&c, &buf)
		world.chunk_destroy(&c)
	}
	// Run twice from a fresh generator and compare the last chunk.
	second: [dynamic]u8
	defer delete(second)
	c: world.Chunk
	world.chunk_init(&c, {7, 2, -2})
	gen.generate(gen.data, &c)
	world.chunk_compact(&c)
	world.chunk_encode(&c, &second)
	world.chunk_destroy(&c)
	testing.expect(
		t,
		string(buf[:]) == string(second[:]),
		"two generations of the same chunk differ",
	)
	testing.expect_value(t, hash.fnv64a(buf[:]), GOLDEN_CHUNK_HASH)
}

// Set from a run; see generation_is_deterministic.
GOLDEN_CHUNK_HASH: u64 : 7610932903885884717

@(test)
world_loads_generates_and_persists :: proc(t: ^testing.T) {
	reg: world.Registry
	world.registry_init(&reg)
	defer world.registry_destroy(&reg)
	world.register_builtin_blocks(&reg)

	flat := world.Flat {
		height = 40,
		block  = STONE,
	}
	store: world.Memory_Storage
	world.memory_storage_init(&store)
	w: world.World
	world.world_init(&w, &reg, world.flat_generator(&flat), world.memory_storage(&store))

	c, err := world.world_load_chunk(&w, {0, 1, 0})
	testing.expect_value(t, err, world.Storage_Error.None)
	// Height 40 means the chunk at y=1 (blocks 32..63) has 8 solid rows.
	testing.expect_value(t, c.non_air, u32(8 * world.CHUNK_AREA))
	testing.expect(t, world.world_is_solid(&w, {5, 39, 5}))
	testing.expect(t, !world.world_is_solid(&w, {5, 40, 5}))
	// Unloaded space is solid.
	testing.expect(t, world.world_is_solid(&w, {500, 500, 500}))

	testing.expect(t, world.world_set_block(&w, {5, 45, 5}, DIRT))
	testing.expect_value(t, world.world_get_block(&w, {5, 45, 5}), DIRT)
	testing.expect(t, !world.world_set_block(&w, {500, 500, 500}, DIRT))

	// Unloading saves; loading again reads the edit back instead of
	// regenerating.
	testing.expect_value(t, world.world_unload_chunk(&w, {0, 1, 0}), world.Storage_Error.None)
	testing.expect(t, world.world_chunk(&w, {0, 1, 0}) == nil)
	c, err = world.world_load_chunk(&w, {0, 1, 0})
	testing.expect_value(t, err, world.Storage_Error.None)
	testing.expect_value(t, world.chunk_get(c, 5, 13, 5), DIRT)
	testing.expect(t, !c.dirty)

	world.world_destroy(&w)
}

@(test)
chunks_around_is_nearest_first :: proc(t: ^testing.T) {
	out: [dynamic]world.Chunk_Pos
	defer delete(out)
	world.chunks_around({1, 2, 3}, 2, &out)
	testing.expect_value(t, len(out), 125)
	testing.expect_value(t, out[0], world.Chunk_Pos{1, 2, 3})
	last: i32
	for p in out {
		d := max(abs(p.x - 1), abs(p.y - 2), abs(p.z - 3))
		testing.expect(t, d >= last, "chunks_around went back toward the center")
		last = d
	}
}
