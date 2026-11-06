// GPU tests. They need an adapter; without one they log that they were
// skipped and pass, so `just test` runs on headless machines (CI uses a
// software adapter where it can).
package test_render

import "core:log"
import "core:slice"
import "core:testing"

import "../../src/mesh"
import "../../src/render"
import "../../src/world"

@(private)
make_registry :: proc() -> world.Registry {
	reg: world.Registry
	world.registry_init(&reg)
	world.register_builtin_blocks(&reg)
	return reg
}

// Sort key: everything but the GPU's slot bits.
@(private)
face_key :: proc(f: mesh.Face) -> u64 {
	return u64(f.a) << 32 | u64(f.b & 0xFFFF)
}

@(test)
range_allocator_coalesces :: proc(t: ^testing.T) {
	a: render.Range_Allocator
	render.range_allocator_init(&a, 100)
	defer render.range_allocator_destroy(&a)
	r1, ok1 := render.range_alloc(&a, 30)
	r2, ok2 := render.range_alloc(&a, 30)
	r3, ok3 := render.range_alloc(&a, 30)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect_value(t, r1.offset, u32(0))
	testing.expect_value(t, r2.offset, u32(30))
	testing.expect_value(t, r3.offset, u32(60))
	_, ok4 := render.range_alloc(&a, 20)
	testing.expect(t, !ok4, "only 10 left")
	render.range_free(&a, r2)
	render.range_free(&a, r1)
	// 0..60 is free again as one range.
	r4, ok5 := render.range_alloc(&a, 60)
	testing.expect(t, ok5)
	testing.expect_value(t, r4.offset, u32(0))
	render.range_free(&a, r3)
	render.range_free(&a, r4)
	testing.expect_value(t, len(a.free), 1)
	testing.expect_value(t, a.free[0], render.Range{0, 100})
	testing.expect_value(t, a.used, u32(0))
}

@(test)
frustum_culls_boxes :: proc(t: ^testing.T) {
	cam := render.DEFAULT_CAMERA
	cam.position = {0, 10, 0}
	// Looking along +z.
	f := render.frustum_from(render.view_projection(cam))
	testing.expect(
		t,
		render.frustum_sees_box(f, {-16, 0, 20}, {16, 32, 52}),
		"a box ahead is visible",
	)
	testing.expect(
		t,
		!render.frustum_sees_box(f, {-16, 0, -60}, {16, 32, -30}),
		"a box behind is culled",
	)
	testing.expect(
		t,
		!render.frustum_sees_box(f, {300, 0, 20}, {332, 32, 52}),
		"a box far to the side is culled",
	)
	testing.expect(
		t,
		render.frustum_sees_box(f, {-1, 9, -1}, {1, 11, 1}),
		"the box around the camera is visible",
	)
}

@(test)
gpu_mesher_matches_cpu :: proc(t: ^testing.T) {
	r: render.Renderer
	if err := render.renderer_init(&r, nil, 64, 64); err != .None {
		log.warnf("no GPU adapter (%v); skipping the GPU test", err)
		return
	}
	defer render.renderer_destroy(&r)
	reg := make_registry()
	defer world.registry_destroy(&reg)
	render.set_registry(&r, &reg)

	// A column of terrain chunks plus a hand-made one with every kind of
	// edge: a single block, a 2x2x2 cube, blocks on the chunk border.
	terrain := world.Terrain {
		params = world.DEFAULT_TERRAIN,
	}
	gen := world.terrain_generator(&terrain)
	chunks: [4]world.Chunk
	for &c, i in chunks {
		world.chunk_init(&c, {0, i32(i), 0})
		gen.generate(gen.data, &c)
	}
	defer for &c in chunks {
		world.chunk_destroy(&c)
	}
	odd: world.Chunk
	world.chunk_init(&odd, {1, 1, 0})
	defer world.chunk_destroy(&odd)
	world.chunk_set(&odd, 5, 6, 7, world.Block_Id(world.Builtin.Brick))
	world.chunk_set(&odd, 0, 6, 7, world.Block_Id(world.Builtin.Stone))
	world.chunk_set(&odd, 31, 31, 31, world.Block_Id(world.Builtin.Sand))
	for x in 10 ..< 12 {
		for y in 10 ..< 12 {
			for z in 10 ..< 12 {
				world.chunk_set(&odd, x, y, z, world.Block_Id(world.Builtin.Log))
			}
		}
	}
	for &c in chunks {
		testing.expect(t, render.upload_chunk(&r, &c))
	}
	testing.expect(t, render.upload_chunk(&r, &odd))

	// Mesh and draw a frame headless.
	cam := render.DEFAULT_CAMERA
	cam.position = {16, 70, -40}
	cam.pitch = -0.4
	testing.expect(t, render.render_frame(&r, cam))
	render.wait_idle(&r)
	with_faces := 0
	for s in r.chunks.slots {
		if s.has_occ && s.faces.length > 0 {
			with_faces += 1
		}
	}
	testing.expect(t, with_faces >= 2, "the ground chunk and the hand-made one have faces")
	testing.expectf(
		t,
		r.chunks.stats.meshed == with_faces,
		"expected %v chunks meshed, got %v",
		with_faces,
		r.chunks.stats.meshed,
	)

	// Compare each chunk's faces with the CPU mesher.
	all := [?]^world.Chunk{&chunks[0], &chunks[1], &chunks[2], &chunks[3], &odd}
	occs: [5]mesh.Occupancy
	for c, i in all {
		mesh.occupancy(c, &reg, &occs[i])
	}
	find_occ :: proc(
		all: []^world.Chunk,
		occs: []mesh.Occupancy,
		pos: world.Chunk_Pos,
	) -> ^mesh.Occupancy {
		for c, i in all {
			if c.pos == pos {
				return &occs[i]
			}
		}
		return nil
	}
	cpu: [dynamic]mesh.Face
	defer delete(cpu)
	for c, i in all {
		n := mesh.Neighborhood {
			center = &occs[i],
		}
		for normal in mesh.Normal {
			d := mesh.NORMAL_DIR[normal]
			n.sides[normal] = find_occ(
				all[:],
				occs[:],
				{c.pos.x + i32(d.x), c.pos.y + i32(d.y), c.pos.z + i32(d.z)},
			)
		}
		clear(&cpu)
		mesh.build_faces(c, n, &cpu)

		slot_index := r.chunks.by_pos[c.pos]
		slot := r.chunks.slots[slot_index]
		testing.expectf(
			t,
			int(slot.faces.length) == len(cpu),
			"chunk %v: GPU range %v faces, CPU %v",
			c.pos,
			slot.faces.length,
			len(cpu),
		)
		if len(cpu) == 0 {
			continue
		}
		// The draw args say how many the GPU wrote.
		args_bytes := render.read_buffer(
			&r,
			r.chunks.indirect,
			u64(slot_index) * size_of(render.Draw_Args),
			size_of(render.Draw_Args),
			context.temp_allocator,
		)
		args := (^render.Draw_Args)(raw_data(args_bytes))^
		testing.expectf(
			t,
			int(args.instance_count) == len(cpu),
			"chunk %v: GPU wrote %v faces, CPU %v",
			c.pos,
			args.instance_count,
			len(cpu),
		)
		testing.expect_value(t, args.first_instance, slot.faces.offset)
		testing.expect_value(t, args.vertex_count, u32(6))

		gpu_bytes := render.read_buffer(
			&r,
			r.chunks.faces,
			u64(slot.faces.offset) * size_of(mesh.Face),
			u64(slot.faces.length) * size_of(mesh.Face),
			context.temp_allocator,
		)
		gpu := slice.reinterpret([]mesh.Face, gpu_bytes)
		if len(gpu) != len(cpu) {
			continue
		}
		keys_gpu := make([]u64, len(gpu), context.temp_allocator)
		keys_cpu := make([]u64, len(cpu), context.temp_allocator)
		for f, j in gpu {
			keys_gpu[j] = face_key(f)
			testing.expect_value(t, f.b >> 16, slot_index)
		}
		for f, j in cpu {
			keys_cpu[j] = face_key(f)
		}
		slice.sort(keys_gpu)
		slice.sort(keys_cpu)
		mismatches := 0
		for j in 0 ..< len(keys_cpu) {
			if keys_gpu[j] != keys_cpu[j] {
				mismatches += 1
			}
		}
		testing.expectf(
			t,
			mismatches == 0,
			"chunk %v: %v of %v faces differ between GPU and CPU",
			c.pos,
			mismatches,
			len(cpu),
		)
	}

	// Removing a chunk frees its ranges and re-dirties neighbors.
	used_before := r.chunks.face_alloc.used
	render.remove_chunk(&r, odd.pos)
	testing.expect(t, r.chunks.face_alloc.used < used_before)
	testing.expect(t, len(r.chunks.dirty) > 0, "neighbors of a removed chunk are re-meshed")
	testing.expect(t, render.render_frame(&r, cam))
	render.wait_idle(&r)
}
