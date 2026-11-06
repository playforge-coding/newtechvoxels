package test_mesh

import "core:slice"
import "core:testing"

import "../../src/mesh"
import "../../src/world"

STONE :: world.Block_Id(world.Builtin.Stone)

@(private)
make_registry :: proc() -> world.Registry {
	reg: world.Registry
	world.registry_init(&reg)
	world.register_builtin_blocks(&reg)
	return reg
}

@(test)
single_block_has_six_open_faces :: proc(t: ^testing.T) {
	reg := make_registry()
	defer world.registry_destroy(&reg)
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	defer world.chunk_destroy(&c)
	world.chunk_set(&c, 5, 6, 7, STONE)

	occ: mesh.Occupancy
	mesh.occupancy(&c, &reg, &occ)
	n := mesh.Neighborhood {
		center = &occ,
	}
	testing.expect_value(t, mesh.count_faces(n), 6)

	faces: [dynamic]mesh.Face
	defer delete(faces)
	mesh.build_faces(&c, n, &faces)
	testing.expect_value(t, len(faces), 6)
	seen: [mesh.Normal]bool
	for f in faces {
		x, y, z, normal, ao, id := mesh.face_unpack(f)
		testing.expect_value(t, [3]int{x, y, z}, [3]int{5, 6, 7})
		testing.expect_value(t, ao, u8(0xFF))
		testing.expect_value(t, id, STONE)
		seen[normal] = true
	}
	for normal in mesh.Normal {
		testing.expect(t, seen[normal], "a normal is missing")
	}
}

@(test)
adjacent_blocks_hide_shared_faces :: proc(t: ^testing.T) {
	reg := make_registry()
	defer world.registry_destroy(&reg)
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	defer world.chunk_destroy(&c)
	world.chunk_set(&c, 5, 6, 7, STONE)
	world.chunk_set(&c, 6, 6, 7, STONE)
	// A 2x2x2 cube: 24 faces.
	world.chunk_set(&c, 20, 20, 20, STONE)
	world.chunk_set(&c, 21, 20, 20, STONE)
	world.chunk_set(&c, 20, 21, 20, STONE)
	world.chunk_set(&c, 21, 21, 20, STONE)
	world.chunk_set(&c, 20, 20, 21, STONE)
	world.chunk_set(&c, 21, 20, 21, STONE)
	world.chunk_set(&c, 20, 21, 21, STONE)
	world.chunk_set(&c, 21, 21, 21, STONE)

	occ: mesh.Occupancy
	mesh.occupancy(&c, &reg, &occ)
	n := mesh.Neighborhood {
		center = &occ,
	}
	faces: [dynamic]mesh.Face
	defer delete(faces)
	mesh.build_faces(&c, n, &faces)
	testing.expect_value(t, len(faces), 10 + 24)
	testing.expect_value(t, mesh.count_faces(n), len(faces))
}

@(test)
neighbors_cull_border_faces :: proc(t: ^testing.T) {
	reg := make_registry()
	defer world.registry_destroy(&reg)
	c, right: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	world.chunk_init(&right, {1, 0, 0})
	defer world.chunk_destroy(&c)
	defer world.chunk_destroy(&right)
	world.chunk_set(&c, 31, 6, 7, STONE)

	occ, occ_right: mesh.Occupancy
	mesh.occupancy(&c, &reg, &occ)
	n := mesh.Neighborhood {
		center = &occ,
	}
	// Without a neighbor the border face shows.
	testing.expect_value(t, mesh.count_faces(n), 6)

	world.chunk_set(&right, 0, 6, 7, STONE)
	mesh.occupancy(&right, &reg, &occ_right)
	n.sides[.Pos_X] = &occ_right
	testing.expect_value(t, mesh.count_faces(n), 5)
	faces: [dynamic]mesh.Face
	defer delete(faces)
	mesh.build_faces(&c, n, &faces)
	testing.expect_value(t, len(faces), 5)
	for f in faces {
		_, _, _, normal, _, _ := mesh.face_unpack(f)
		testing.expect(t, normal != .Pos_X, "the +x face should be hidden by the neighbor")
	}
}

@(test)
ambient_occlusion_darkens_corners :: proc(t: ^testing.T) {
	reg := make_registry()
	defer world.registry_destroy(&reg)
	c: world.Chunk
	world.chunk_init(&c, {0, 0, 0})
	defer world.chunk_destroy(&c)
	// A floor with one block standing on it: the floor faces touching the
	// block are occluded at the corners next to it.
	for x in 0 ..< 8 {
		for z in 0 ..< 8 {
			world.chunk_set(&c, x, 0, z, STONE)
		}
	}
	world.chunk_set(&c, 4, 1, 4, STONE)
	occ: mesh.Occupancy
	mesh.occupancy(&c, &reg, &occ)
	n := mesh.Neighborhood {
		center = &occ,
	}
	// The top face of the floor block at (3, 0, 4), next to the standing
	// block on its +x side: corners 1 and 3 (the +x corners) are occluded.
	ao := mesh.face_ao(n, 3, 0, 4, .Pos_Y)
	testing.expect_value(t, ao & 3, u8(3))
	testing.expect_value(t, ao >> 2 & 3, u8(2))
	testing.expect_value(t, ao >> 4 & 3, u8(3))
	testing.expect_value(t, ao >> 6 & 3, u8(2))
	// A diagonal neighbor only: the corner between them drops by one.
	ao = mesh.face_ao(n, 3, 0, 3, .Pos_Y)
	testing.expect_value(t, ao >> 6 & 3, u8(2))
	testing.expect_value(t, ao & 3, u8(3))
}

@(test)
count_matches_build_on_terrain :: proc(t: ^testing.T) {
	reg := make_registry()
	defer world.registry_destroy(&reg)
	terrain := world.Terrain {
		params = world.DEFAULT_TERRAIN,
	}
	gen := world.terrain_generator(&terrain)

	// A column of chunks with their vertical neighbors, so border culling
	// is exercised.
	chunks: [4]world.Chunk
	occs: [4]mesh.Occupancy
	for &c, i in chunks {
		world.chunk_init(&c, {2, i32(i) - 1, 3})
		gen.generate(gen.data, &c)
		mesh.occupancy(&c, &reg, &occs[i])
	}
	defer for &c in chunks {
		world.chunk_destroy(&c)
	}
	faces: [dynamic]mesh.Face
	defer delete(faces)
	total := 0
	for i in 0 ..< 4 {
		n := mesh.Neighborhood {
			center = &occs[i],
		}
		if i > 0 {
			n.sides[.Neg_Y] = &occs[i - 1]
		}
		if i < 3 {
			n.sides[.Pos_Y] = &occs[i + 1]
		}
		clear(&faces)
		mesh.build_faces(&chunks[i], n, &faces)
		testing.expect_value(t, mesh.count_faces(n), len(faces))
		total += len(faces)
		// No duplicates: a face is identified by position and normal.
		keys := make([]u32, len(faces), context.temp_allocator)
		for f, j in faces {
			keys[j] = f.a & 0x3FFFF
		}
		slice.sort(keys)
		for j in 1 ..< len(keys) {
			if keys[j] == keys[j - 1] {
				testing.fail_now(t, "duplicate face")
			}
		}
	}
	testing.expect(t, total > 1000, "terrain should produce faces")
}
