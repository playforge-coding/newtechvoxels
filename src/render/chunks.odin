// Chunk rendering: chunks get a slot with a record on the GPU, their
// packed voxels and palette go into one big voxel buffer, a compute pass
// writes their faces into their range of one big face buffer, and one
// indirect draw per visible chunk reads them back out. The CPU only ever
// uploads: it sizes each face range from the exact popcount in src/mesh.
package render

import "core:log"

import "vendor:wgpu"

import "../mesh"
import "../world"

// Mirrors `ChunkRecord` in the shaders.
Chunk_Record :: struct {
	data_offset:    u32,
	palette_offset: u32,
	bits:           u32,
	palette_len:    u32,
	neighbors:      [6]u32,
	face_offset:    u32,
	face_capacity:  u32,
	px, py, pz:     i32,
	pad:            u32,
}
#assert(size_of(Chunk_Record) == 64)

// Mirrors `DrawArgs` in the shaders and wgpu's indirect draw layout.
Draw_Args :: struct {
	vertex_count:   u32,
	instance_count: u32,
	first_vertex:   u32,
	first_instance: u32,
}
#assert(size_of(Draw_Args) == 16)

NO_SLOT :: max(u32)

// Capacities. These are the renderer's memory budget; a chunk that doesn't
// fit is skipped with a logged warning rather than crashing.
MAX_CHUNKS :: 4096
VOXEL_WORDS :: 6 * 1024 * 1024 // 24 MB
FACE_CAPACITY :: 6 * 1024 * 1024 // 48 MB
MAX_DIRTY_PER_FRAME :: 256

Slot :: struct {
	pos:         world.Chunk_Pos,
	voxels:      Range,
	faces:       Range,
	// The chunk needs its record and faces rebuilt.
	dirty:       bool,
	// Occupancy, kept so neighbors can be counted without the chunk.
	occ:         mesh.Occupancy,
	has_occ:     bool,
	empty:       bool,
	// How the voxel range is laid out: palette words first, then data.
	palette_len: u32,
	bits:        u8,
}

Chunk_Renderer :: struct {
	registry:      ^world.Registry,
	voxels:        wgpu.Buffer,
	faces:         wgpu.Buffer,
	records:       wgpu.Buffer,
	indirect:      wgpu.Buffer,
	dirty_buf:     wgpu.Buffer,
	camera_buf:    wgpu.Buffer,
	blocks:        wgpu.Buffer,
	block_count:   int,
	voxel_alloc:   Range_Allocator,
	face_alloc:    Range_Allocator,
	slots:         [dynamic]Slot,
	free_slots:    [dynamic]u32,
	by_pos:        map[world.Chunk_Pos]u32,
	dirty:         [dynamic]u32,
	mesh_pipeline: wgpu.ComputePipeline,
	mesh_layout:   wgpu.BindGroupLayout,
	mesh_bind:     wgpu.BindGroup,
	draw_pipeline: wgpu.RenderPipeline,
	draw_layout:   wgpu.BindGroupLayout,
	draw_bind:     wgpu.BindGroup,
	// Counters for telemetry, reset by the caller.
	stats:         Chunk_Stats,
}

Chunk_Stats :: struct {
	meshed:      int,
	drawn:       int,
	faces_drawn: int,
	uploaded:    int,
	skipped:     int,
}

MESH_WGSL :: #load("../../shaders/mesh.wgsl", string)
CHUNK_WGSL :: #load("../../shaders/chunk.wgsl", string)

@(private = "file")
make_buffer :: proc(
	r: ^Renderer,
	label: string,
	size: u64,
	usage: wgpu.BufferUsageFlags,
) -> wgpu.Buffer {
	return wgpu.DeviceCreateBuffer(r.device, &{label = label, size = size, usage = usage})
}

@(private = "file")
storage_entry :: proc(
	binding: u32,
	read_only: bool,
	stages: wgpu.ShaderStageFlags,
) -> wgpu.BindGroupLayoutEntry {
	return {
		binding = binding,
		visibility = stages,
		buffer = {type = read_only ? .ReadOnlyStorage : .Storage},
	}
}

@(private = "file")
buffer_entry :: proc(binding: u32, buffer: wgpu.Buffer, size: u64) -> wgpu.BindGroupEntry {
	return {binding = binding, buffer = buffer, size = size}
}

chunk_renderer_init :: proc(r: ^Renderer) {
	c := &r.chunks
	c.voxels = make_buffer(r, "voxels", VOXEL_WORDS * 4, {.Storage, .CopyDst})
	c.faces = make_buffer(r, "faces", FACE_CAPACITY * size_of(mesh.Face), {.Storage, .CopySrc})
	c.records = make_buffer(
		r,
		"chunk records",
		MAX_CHUNKS * size_of(Chunk_Record),
		{.Storage, .CopyDst},
	)
	c.indirect = make_buffer(
		r,
		"indirect",
		MAX_CHUNKS * size_of(Draw_Args),
		{.Storage, .Indirect, .CopyDst, .CopySrc},
	)
	c.dirty_buf = make_buffer(r, "dirty", MAX_DIRTY_PER_FRAME * 4, {.Storage, .CopyDst})
	c.camera_buf = make_buffer(r, "camera", size_of(Camera_Uniform), {.Uniform, .CopyDst})
	// Filled by chunk_renderer_set_registry; 16 bytes per block.
	c.blocks = make_buffer(r, "blocks", 65536 * 16, {.Storage, .CopyDst})

	range_allocator_init(&c.voxel_alloc, VOXEL_WORDS)
	range_allocator_init(&c.face_alloc, FACE_CAPACITY)
	c.slots = make([dynamic]Slot, 0, 512)
	c.free_slots = make([dynamic]u32, 0, 64)
	c.by_pos = make(map[world.Chunk_Pos]u32)
	c.dirty = make([dynamic]u32, 0, 256)

	// Meshing pipeline.
	mesh_module := wgpu.DeviceCreateShaderModule(
		r.device,
		&{
			label = "mesh",
			nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = MESH_WGSL},
		},
	)
	defer wgpu.ShaderModuleRelease(mesh_module)
	mesh_entries := [?]wgpu.BindGroupLayoutEntry {
		storage_entry(0, true, {.Compute}),
		storage_entry(1, true, {.Compute}),
		storage_entry(2, true, {.Compute}),
		storage_entry(3, false, {.Compute}),
		storage_entry(4, false, {.Compute}),
		storage_entry(5, true, {.Compute}),
	}
	c.mesh_layout = wgpu.DeviceCreateBindGroupLayout(
		r.device,
		&{label = "mesh", entryCount = len(mesh_entries), entries = raw_data(mesh_entries[:])},
	)
	mesh_pl := wgpu.DeviceCreatePipelineLayout(
		r.device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &c.mesh_layout},
	)
	defer wgpu.PipelineLayoutRelease(mesh_pl)
	c.mesh_pipeline = wgpu.DeviceCreateComputePipeline(
		r.device,
		&{
			label = "mesh",
			layout = mesh_pl,
			compute = {module = mesh_module, entryPoint = "mesh_chunk"},
		},
	)
	mesh_binds := [?]wgpu.BindGroupEntry {
		buffer_entry(0, c.voxels, VOXEL_WORDS * 4),
		buffer_entry(1, c.records, MAX_CHUNKS * size_of(Chunk_Record)),
		buffer_entry(2, c.blocks, 65536 * 16),
		buffer_entry(3, c.faces, FACE_CAPACITY * size_of(mesh.Face)),
		buffer_entry(4, c.indirect, MAX_CHUNKS * size_of(Draw_Args)),
		buffer_entry(5, c.dirty_buf, MAX_DIRTY_PER_FRAME * 4),
	}
	c.mesh_bind = wgpu.DeviceCreateBindGroup(
		r.device,
		&{layout = c.mesh_layout, entryCount = len(mesh_binds), entries = raw_data(mesh_binds[:])},
	)

	// Drawing pipeline.
	draw_module := wgpu.DeviceCreateShaderModule(
		r.device,
		&{
			label = "chunk",
			nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = CHUNK_WGSL},
		},
	)
	defer wgpu.ShaderModuleRelease(draw_module)
	draw_entries := [?]wgpu.BindGroupLayoutEntry {
		{binding = 0, visibility = {.Vertex, .Fragment}, buffer = {type = .Uniform}},
		storage_entry(1, true, {.Vertex}),
		storage_entry(2, true, {.Vertex}),
		storage_entry(3, true, {.Vertex}),
	}
	c.draw_layout = wgpu.DeviceCreateBindGroupLayout(
		r.device,
		&{label = "chunk", entryCount = len(draw_entries), entries = raw_data(draw_entries[:])},
	)
	draw_pl := wgpu.DeviceCreatePipelineLayout(
		r.device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &c.draw_layout},
	)
	defer wgpu.PipelineLayoutRelease(draw_pl)
	c.draw_pipeline = wgpu.DeviceCreateRenderPipeline(
		r.device,
		&{
			label = "chunk",
			layout = draw_pl,
			vertex = {module = draw_module, entryPoint = "vs_main"},
			fragment = &{
				module = draw_module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = r.format,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList, cullMode = .None},
			depthStencil = &{
				format = .Depth24Plus,
				depthWriteEnabled = .True,
				depthCompare = .Less,
			},
			multisample = {count = 1, mask = 0xFFFFFFFF},
		},
	)
	draw_binds := [?]wgpu.BindGroupEntry {
		buffer_entry(0, c.camera_buf, size_of(Camera_Uniform)),
		buffer_entry(1, c.faces, FACE_CAPACITY * size_of(mesh.Face)),
		buffer_entry(2, c.records, MAX_CHUNKS * size_of(Chunk_Record)),
		buffer_entry(3, c.blocks, 65536 * 16),
	}
	c.draw_bind = wgpu.DeviceCreateBindGroup(
		r.device,
		&{layout = c.draw_layout, entryCount = len(draw_binds), entries = raw_data(draw_binds[:])},
	)
}

chunk_renderer_destroy :: proc(r: ^Renderer) {
	c := &r.chunks
	if c.voxels == nil {
		return
	}
	wgpu.BindGroupRelease(c.mesh_bind)
	wgpu.BindGroupRelease(c.draw_bind)
	wgpu.BindGroupLayoutRelease(c.mesh_layout)
	wgpu.BindGroupLayoutRelease(c.draw_layout)
	wgpu.ComputePipelineRelease(c.mesh_pipeline)
	wgpu.RenderPipelineRelease(c.draw_pipeline)
	for b in ([]wgpu.Buffer{c.voxels, c.faces, c.records, c.indirect, c.dirty_buf, c.camera_buf, c.blocks}) {
		wgpu.BufferRelease(b)
	}
	range_allocator_destroy(&c.voxel_alloc)
	range_allocator_destroy(&c.face_alloc)
	delete(c.slots)
	delete(c.free_slots)
	delete(c.by_pos)
	delete(c.dirty)
}

// Uploads the block table (color and solidity) from a registry. Call it
// once blocks are registered, and again when they change.
set_registry :: proc(r: ^Renderer, registry: ^world.Registry) {
	c := &r.chunks
	c.registry = registry
	table := make([][4]f32, len(registry.defs), context.temp_allocator)
	for d, i in registry.defs {
		table[i] = {
			f32(d.color.r) / 255,
			f32(d.color.g) / 255,
			f32(d.color.b) / 255,
			d.solid ? 1 : 0,
		}
	}
	c.block_count = len(table)
	wgpu.QueueWriteBuffer(r.queue, c.blocks, 0, raw_data(table), uint(len(table)) * 16)
}

// Puts a chunk in the renderer or updates it: uploads its packed form,
// sizes its face range, and marks it and its neighbors dirty. Returns
// false when the chunk doesn't fit the GPU budget.
upload_chunk :: proc(r: ^Renderer, chunk: ^world.Chunk) -> bool {
	c := &r.chunks
	slot_index, exists := c.by_pos[chunk.pos]
	if !exists {
		if len(c.free_slots) > 0 {
			slot_index = pop(&c.free_slots)
		} else if len(c.slots) < MAX_CHUNKS {
			slot_index = u32(len(c.slots))
			append(&c.slots, Slot{})
		} else {
			c.stats.skipped += 1
			return false
		}
		c.slots[slot_index] = Slot {
			pos = chunk.pos,
		}
		c.by_pos[chunk.pos] = slot_index
	}
	s := &c.slots[slot_index]

	// Voxel words: palette entries then data words.
	range_free(&c.voxel_alloc, s.voxels)
	s.voxels = {}
	words := u32(len(chunk.palette) + len(chunk.data))
	voxels, ok := range_alloc(&c.voxel_alloc, words)
	if !ok {
		log.warn("voxel buffer full; chunk skipped")
		c.stats.skipped += 1
		return false
	}
	s.voxels = voxels
	upload := make([]u32, words, context.temp_allocator)
	for id, i in chunk.palette {
		upload[i] = u32(id)
	}
	copy(upload[len(chunk.palette):], chunk.data[:])
	wgpu.QueueWriteBuffer(
		r.queue,
		c.voxels,
		u64(voxels.offset) * 4,
		raw_data(upload),
		uint(words) * 4,
	)
	c.stats.uploaded += 1

	mesh.occupancy(chunk, c.registry, &s.occ)
	s.has_occ = true
	s.empty = world.chunk_is_empty(chunk)
	s.palette_len = u32(len(chunk.palette))
	s.bits = chunk.bits
	mark_dirty(c, slot_index)
	// Neighbors see a different border now.
	for n in mesh.Normal {
		d := mesh.NORMAL_DIR[n]
		npos := world.Chunk_Pos {
			chunk.pos.x + i32(d.x),
			chunk.pos.y + i32(d.y),
			chunk.pos.z + i32(d.z),
		}
		if ni, nok := c.by_pos[npos]; nok {
			mark_dirty(c, ni)
		}
	}
	return true
}

// Frees a chunk's GPU memory.
remove_chunk :: proc(r: ^Renderer, pos: world.Chunk_Pos) {
	c := &r.chunks
	slot_index, ok := c.by_pos[pos]
	if !ok {
		return
	}
	s := &c.slots[slot_index]
	range_free(&c.voxel_alloc, s.voxels)
	range_free(&c.face_alloc, s.faces)
	delete_key(&c.by_pos, pos)
	s^ = {}
	append(&c.free_slots, slot_index)
	// Neighbors lose a border.
	for n in mesh.Normal {
		d := mesh.NORMAL_DIR[n]
		npos := world.Chunk_Pos{pos.x + i32(d.x), pos.y + i32(d.y), pos.z + i32(d.z)}
		if ni, nok := c.by_pos[npos]; nok {
			mark_dirty(c, ni)
		}
	}
	// A removed chunk must not be drawn: zero its args.
	args := Draw_Args{}
	wgpu.QueueWriteBuffer(
		r.queue,
		c.indirect,
		u64(slot_index) * size_of(Draw_Args),
		&args,
		size_of(Draw_Args),
	)
}

@(private = "file")
mark_dirty :: proc(c: ^Chunk_Renderer, slot: u32) {
	if !c.slots[slot].dirty {
		c.slots[slot].dirty = true
		append(&c.dirty, slot)
	}
}

@(private = "file")
neighborhood :: proc(c: ^Chunk_Renderer, s: ^Slot) -> (n: mesh.Neighborhood, slots: [6]u32) {
	n.center = &s.occ
	for normal in mesh.Normal {
		d := mesh.NORMAL_DIR[normal]
		npos := world.Chunk_Pos{s.pos.x + i32(d.x), s.pos.y + i32(d.y), s.pos.z + i32(d.z)}
		slots[normal] = NO_SLOT
		if ni, ok := c.by_pos[npos]; ok {
			slots[normal] = ni
			n.sides[normal] = &c.slots[ni].occ
		}
	}
	return
}

// Records and meshes up to MAX_DIRTY_PER_FRAME dirty chunks: writes their
// records and zeroed draw arguments, then runs the meshing compute pass
// into `encoder`. Call before the render pass of a frame.
mesh_dirty :: proc(r: ^Renderer, encoder: wgpu.CommandEncoder) {
	c := &r.chunks
	if len(c.dirty) == 0 {
		return
	}
	count := min(len(c.dirty), MAX_DIRTY_PER_FRAME)
	list := make([dynamic]u32, 0, count, context.temp_allocator)
	for i in 0 ..< count {
		slot_index := c.dirty[i]
		s := &c.slots[slot_index]
		s.dirty = false
		if !s.has_occ {
			// Removed before it was meshed.
			continue
		}
		n, neighbor_slots := neighborhood(c, s)
		faces := u32(mesh.count_faces(n))
		range_free(&c.face_alloc, s.faces)
		s.faces = {}
		if faces > 0 {
			rng, ok := range_alloc(&c.face_alloc, faces)
			if !ok {
				log.warn("face buffer full; chunk not meshed")
				c.stats.skipped += 1
				continue
			}
			s.faces = rng
		}
		record := Chunk_Record {
			data_offset    = s.voxels.offset + s.palette_len,
			palette_offset = s.voxels.offset,
			bits           = u32(s.bits),
			palette_len    = s.palette_len,
			neighbors      = neighbor_slots,
			face_offset    = s.faces.offset,
			face_capacity  = faces,
			px             = s.pos.x,
			py             = s.pos.y,
			pz             = s.pos.z,
		}
		wgpu.QueueWriteBuffer(
			r.queue,
			c.records,
			u64(slot_index) * size_of(Chunk_Record),
			&record,
			size_of(Chunk_Record),
		)
		args := Draw_Args {
			vertex_count   = 6,
			instance_count = 0,
			first_vertex   = 0,
			first_instance = s.faces.offset,
		}
		wgpu.QueueWriteBuffer(
			r.queue,
			c.indirect,
			u64(slot_index) * size_of(Draw_Args),
			&args,
			size_of(Draw_Args),
		)
		if faces > 0 {
			append(&list, slot_index)
		}
	}
	remove_range(&c.dirty, 0, count)
	if len(list) == 0 {
		return
	}
	wgpu.QueueWriteBuffer(r.queue, c.dirty_buf, 0, raw_data(list), uint(len(list)) * 4)
	pass := wgpu.CommandEncoderBeginComputePass(encoder, nil)
	wgpu.ComputePassEncoderSetPipeline(pass, c.mesh_pipeline)
	wgpu.ComputePassEncoderSetBindGroup(pass, 0, c.mesh_bind)
	wgpu.ComputePassEncoderDispatchWorkgroups(pass, world.CHUNK_VOLUME / 256, u32(len(list)), 1)
	wgpu.ComputePassEncoderEnd(pass)
	wgpu.ComputePassEncoderRelease(pass)
	c.stats.meshed += len(list)
}

// Draws every chunk the frustum sees into an open render pass.
draw_chunks :: proc(r: ^Renderer, pass: wgpu.RenderPassEncoder, camera: Camera) {
	c := &r.chunks
	uniform := Camera_Uniform {
		view_proj = view_projection(camera),
		position  = {camera.position.x, camera.position.y, camera.position.z, 1},
		sun       = {0.45, 0.8, 0.35, 0},
	}
	wgpu.QueueWriteBuffer(r.queue, c.camera_buf, 0, &uniform, size_of(uniform))
	frustum := frustum_from(uniform.view_proj)

	wgpu.RenderPassEncoderSetPipeline(pass, c.draw_pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, c.draw_bind)
	for &s, i in c.slots {
		if !s.has_occ || s.faces.length == 0 || s.dirty {
			continue
		}
		lo := [3]f32{f32(s.pos.x), f32(s.pos.y), f32(s.pos.z)} * world.CHUNK_SIZE
		hi := lo + world.CHUNK_SIZE
		if !frustum_sees_box(frustum, lo, hi) {
			continue
		}
		wgpu.RenderPassEncoderDrawIndirect(pass, c.indirect, u64(i) * size_of(Draw_Args))
		c.stats.drawn += 1
		c.stats.faces_drawn += int(s.faces.length)
	}
}
