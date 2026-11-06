package test_storage

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "sdk:zstd"

import "../../src/storage"
import "../../src/world"

STONE :: world.Block_Id(world.Builtin.Stone)
DIRT :: world.Block_Id(world.Builtin.Dirt)

// A fresh directory under the system temp dir for one test.
temp_dir :: proc(name: string) -> string {
	base, terr := os.temp_directory(context.temp_allocator)
	if terr != nil {
		base = "/tmp"
	}
	path, _ := filepath.join(
		{base, fmt.tprintf("ntv-%s-%d", name, time.now()._nsec)},
		context.temp_allocator,
	)
	return path
}

region_file :: proc(dir, name: string) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

@(test)
zstd_round_trips_and_caps :: proc(t: ^testing.T) {
	data := make([]u8, 100_000)
	defer delete(data)
	for &b, i in data {
		b = u8(i % 37)
	}
	packed, err := zstd.compress_slice(data)
	defer delete(packed)
	testing.expect_value(t, err, zstd.Error.None)
	testing.expect(t, len(packed) < len(data) / 10, "repetitive data should compress well")

	back, derr := zstd.decompress_slice(packed, len(data))
	defer delete(back)
	testing.expect_value(t, derr, zstd.Error.None)
	testing.expect(t, string(back) == string(data))

	// Refused when the declared size is over the cap.
	_, derr = zstd.decompress_slice(packed, len(data) - 1)
	testing.expect_value(t, derr, zstd.Error.Too_Large)
	// Garbage is an error, not a crash.
	_, derr = zstd.decompress_slice({1, 2, 3, 4, 5}, 1000)
	testing.expect(t, derr != .None)
	// Empty input works.
	e, eerr := zstd.compress_slice({})
	defer delete(e)
	testing.expect_value(t, eerr, zstd.Error.None)
	eb, ederr := zstd.decompress_slice(e, 10)
	testing.expect_value(t, ederr, zstd.Error.None)
	testing.expect_value(t, len(eb), 0)
}

@(test)
region_files_save_and_load :: proc(t: ^testing.T) {
	dir := temp_dir("region")
	fs: storage.File_Storage
	testing.expect_value(t, storage.file_storage_init(&fs, dir), world.Storage_Error.None)
	store := storage.file_storage(&fs)
	defer world.storage_destroy(store)

	// Three chunks in the same region and one in another, with a rewrite.
	positions := [?]world.Chunk_Pos{{0, 0, 0}, {7, 7, 7}, {3, -1, 2}, {-1, 0, 0}}
	for pos, i in positions {
		c: world.Chunk
		world.chunk_init(&c, pos)
		world.chunk_set(&c, i, i, i, STONE)
		world.chunk_set(&c, 0, 0, 1, DIRT)
		testing.expect_value(t, world.storage_save(store, &c), world.Storage_Error.None)
		world.chunk_destroy(&c)
	}
	// Overwrite the first.
	{
		c: world.Chunk
		world.chunk_init(&c, {0, 0, 0})
		world.chunk_fill(&c, DIRT)
		testing.expect_value(t, world.storage_save(store, &c), world.Storage_Error.None)
		world.chunk_destroy(&c)
	}
	for pos, i in positions {
		c: world.Chunk
		found, err := world.storage_load(store, pos, &c)
		testing.expect(t, found, "saved chunk not found")
		testing.expect_value(t, err, world.Storage_Error.None)
		testing.expect_value(t, c.pos, pos)
		if i == 0 {
			testing.expect(t, world.chunk_is_full(&c))
		} else {
			testing.expect_value(t, world.chunk_get(&c, i, i, i), STONE)
			testing.expect_value(t, world.chunk_get(&c, 0, 0, 1), DIRT)
		}
		world.chunk_destroy(&c)
	}
	// A chunk never saved, in an existing region and in a missing one.
	c: world.Chunk
	found, err := world.storage_load(store, {1, 1, 1}, &c)
	testing.expect(t, !found)
	testing.expect_value(t, err, world.Storage_Error.None)
	found, err = world.storage_load(store, {100, 100, 100}, &c)
	testing.expect(t, !found)
	testing.expect_value(t, err, world.Storage_Error.None)

	// Two region files exist: (0,0,0) with three chunks, and (-1,0,0).
	testing.expect(t, os.exists(region_file(dir, "r.0.0.0.ntvr")))
	testing.expect(t, os.exists(region_file(dir, "r.-1.0.0.ntvr")))
}

@(test)
corrupt_region_is_an_error :: proc(t: ^testing.T) {
	dir := temp_dir("corrupt")
	fs: storage.File_Storage
	testing.expect_value(t, storage.file_storage_init(&fs, dir), world.Storage_Error.None)
	store := storage.file_storage(&fs)
	defer world.storage_destroy(store)
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	world.chunk_set(&c, 1, 1, 1, STONE)
	testing.expect_value(t, world.storage_save(store, &c), world.Storage_Error.None)
	world.chunk_destroy(&c)

	path := region_file(dir, "r.0.0.0.ntvr")
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	// Flip bytes in the frame.
	for i in storage.HEADER_SIZE ..< len(data) {
		data[i] = ~data[i]
	}
	testing.expect(t, os.write_entire_file(path, data) == nil)
	found, err := world.storage_load(store, {0, 0, 0}, &c)
	testing.expect(t, found)
	testing.expect_value(t, err, world.Storage_Error.Corrupt)

	// A table entry pointing past the file.
	data[8] = 0xFF
	data[9] = 0xFF
	data[10] = 0xFF
	data[11] = 0x7F
	testing.expect(t, os.write_entire_file(path, data) == nil)
	found, err = world.storage_load(store, {0, 0, 0}, &c)
	testing.expect_value(t, err, world.Storage_Error.Corrupt)

	// A bad magic.
	data[0] = 'X'
	testing.expect(t, os.write_entire_file(path, data) == nil)
	_, err = world.storage_load(store, {0, 0, 0}, &c)
	testing.expect_value(t, err, world.Storage_Error.Corrupt)
}

@(test)
world_round_trips_through_files :: proc(t: ^testing.T) {
	dir := temp_dir("world")
	reg: world.Registry
	world.registry_init(&reg)
	defer world.registry_destroy(&reg)
	world.register_builtin_blocks(&reg)
	terrain := world.Terrain {
		params = world.DEFAULT_TERRAIN,
	}

	// Generate, edit, save by destroying the world.
	fs: storage.File_Storage
	testing.expect_value(t, storage.file_storage_init(&fs, dir), world.Storage_Error.None)
	w: world.World
	world.world_init(&w, &reg, world.terrain_generator(&terrain), storage.file_storage(&fs))
	c, _ := world.world_load_chunk(&w, {0, 0, 0})
	original := c.non_air
	testing.expect(t, world.world_set_block(&w, {5, 5, 5}, world.Block_Id(world.Builtin.Brick)))
	world.world_destroy(&w)

	// A new world over the same directory with a different generator reads
	// the saved chunk, edit included, instead of generating.
	flat := world.Flat {
		height = 1,
		block  = STONE,
	}
	fs2: storage.File_Storage
	testing.expect_value(t, storage.file_storage_init(&fs2, dir), world.Storage_Error.None)
	w2: world.World
	world.world_init(&w2, &reg, world.flat_generator(&flat), storage.file_storage(&fs2))
	defer world.world_destroy(&w2)
	c2, err := world.world_load_chunk(&w2, {0, 0, 0})
	testing.expect_value(t, err, world.Storage_Error.None)
	testing.expect_value(t, world.chunk_get(c2, 5, 5, 5), world.Block_Id(world.Builtin.Brick))
	// Same as the original plus or minus the one edit.
	testing.expect(t, c2.non_air == original || c2.non_air == original + 1)
}
