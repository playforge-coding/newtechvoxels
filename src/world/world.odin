// The world: loaded chunks, the registry they refer to, where new chunks
// come from and where changed ones go. Several worlds can exist in one
// process; nothing here is global.
package world

import "core:mem"

World :: struct {
	registry:  ^Registry,
	generator: Generator,
	storage:   Storage,
	chunks:    map[Chunk_Pos]^Chunk,
	allocator: mem.Allocator,
	// Chunk positions in the order they were loaded, for eviction.
	loaded:    [dynamic]Chunk_Pos,
}

world_init :: proc(
	w: ^World,
	registry: ^Registry,
	generator: Generator,
	storage: Storage = {},
	allocator := context.allocator,
) {
	w.registry = registry
	w.generator = generator
	w.storage = storage
	w.allocator = allocator
	w.chunks = make(map[Chunk_Pos]^Chunk, allocator)
	w.loaded = make([dynamic]Chunk_Pos, 0, 256, allocator)
}

// Saves what's dirty, then frees everything. The storage is destroyed too.
world_destroy :: proc(w: ^World) {
	world_save_dirty(w)
	for _, c in w.chunks {
		chunk_destroy(c)
		free(c, w.allocator)
	}
	delete(w.chunks)
	delete(w.loaded)
	storage_destroy(w.storage)
}

// The chunk if it's loaded, else nil. Never loads or generates.
world_chunk :: proc(w: ^World, pos: Chunk_Pos) -> ^Chunk {
	return w.chunks[pos] or_else nil
}

// The chunk at a position, loaded from storage or generated when it isn't
// in memory yet. `err` is set when the storage failed; the chunk is then
// generated fresh so the caller still gets one.
world_load_chunk :: proc(w: ^World, pos: Chunk_Pos) -> (c: ^Chunk, err: Storage_Error) {
	if existing, ok := w.chunks[pos]; ok {
		return existing, .None
	}
	c = new(Chunk, w.allocator)
	found: bool
	found, err = storage_load(w.storage, pos, c, w.allocator)
	if !found || err != .None {
		chunk_init(c, pos, AIR, w.allocator)
		if w.generator.generate != nil {
			w.generator.generate(w.generator.data, c)
		}
		// Generated content is new, so it's dirty for the storage; a chunk
		// read back from storage is clean for it.
		c.dirty = true
	} else {
		c.dirty = false
	}
	w.chunks[pos] = c
	append(&w.loaded, pos)
	return c, err
}

// Writes a chunk to storage if it changed since the last save and drops it
// from memory.
world_unload_chunk :: proc(w: ^World, pos: Chunk_Pos) -> Storage_Error {
	c, ok := w.chunks[pos]
	if !ok {
		return .None
	}
	err: Storage_Error
	if c.dirty {
		err = storage_save(w.storage, c)
	}
	delete_key(&w.chunks, pos)
	for p, i in w.loaded {
		if p == pos {
			unordered_remove(&w.loaded, i)
			break
		}
	}
	chunk_destroy(c)
	free(c, w.allocator)
	return err
}

// Saves every dirty chunk and marks them clean. Returns the first error.
world_save_dirty :: proc(w: ^World) -> Storage_Error {
	first: Storage_Error
	for _, c in w.chunks {
		if c.dirty {
			if err := storage_save(w.storage, c); err != .None {
				if first == .None {
					first = err
				}
			} else {
				c.dirty = false
			}
		}
	}
	return first
}

// The block at a world position. Air where no chunk is loaded.
world_get_block :: proc(w: ^World, p: Block_Pos) -> Block_Id {
	cpos, x, y, z := split_block_pos(p)
	c := w.chunks[cpos] or_else nil
	if c == nil {
		return AIR
	}
	return chunk_get(c, x, y, z)
}

// Sets a block in a loaded chunk. Returns false when the chunk isn't loaded
// or the block was already that; both leave the world unchanged.
world_set_block :: proc(w: ^World, p: Block_Pos, id: Block_Id) -> bool {
	cpos, x, y, z := split_block_pos(p)
	c := w.chunks[cpos] or_else nil
	if c == nil {
		return false
	}
	return chunk_set(c, x, y, z, id)
}

// Whether a block position is inside a solid block. Unloaded space counts
// as solid, so nothing walks or falls into chunks that don't exist yet.
world_is_solid :: proc(w: ^World, p: Block_Pos) -> bool {
	cpos, x, y, z := split_block_pos(p)
	c := w.chunks[cpos] or_else nil
	if c == nil {
		return true
	}
	return is_solid(w.registry, chunk_get(c, x, y, z))
}

// The chunk positions within `radius` chunks of `center`, nearest first,
// appended to `out`. The callers that stream chunks to players use it.
chunks_around :: proc(center: Chunk_Pos, radius: i32, out: ^[dynamic]Chunk_Pos) {
	// Shells from the inside out keep the nearest chunks first without a
	// sort.
	for r in 0 ..= radius {
		for dy in -r ..= r {
			for dz in -r ..= r {
				for dx in -r ..= r {
					if max(abs(dx), abs(dy), abs(dz)) != r {
						continue
					}
					append(out, Chunk_Pos{center.x + dx, center.y + dy, center.z + dz})
				}
			}
		}
	}
}

// The chunk a world position (in blocks, possibly fractional) is in.
chunk_pos_of :: proc "contextless" (p: [3]f32) -> Chunk_Pos {
	return Chunk_Pos {
		floor_i32(p.x / CHUNK_SIZE),
		floor_i32(p.y / CHUNK_SIZE),
		floor_i32(p.z / CHUNK_SIZE),
	}
}

// The block a world position is in.
block_pos_of :: proc "contextless" (p: [3]f32) -> Block_Pos {
	return Block_Pos{floor_i32(p.x), floor_i32(p.y), floor_i32(p.z)}
}

floor_i32 :: proc "contextless" (v: f32) -> i32 {
	i := i32(v)
	if f32(i) > v {
		i -= 1
	}
	return i
}

// Adds a chunk that came from elsewhere (the network) to the world, taking
// ownership of it. Replaces a loaded chunk at the same position.
world_insert_chunk :: proc(w: ^World, c: Chunk) -> ^Chunk {
	if old, ok := w.chunks[c.pos]; ok {
		chunk_destroy(old)
		old^ = c
		old.dirty = true
		return old
	}
	p := new(Chunk, w.allocator)
	p^ = c
	p.dirty = true
	w.chunks[c.pos] = p
	append(&w.loaded, c.pos)
	return p
}
