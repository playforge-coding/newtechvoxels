// Where chunks persist. The world asks its storage for a chunk before it
// generates one, and hands dirty chunks back. The interface is a struct of
// procedures; the in-memory implementation here serves tests and sessions
// that shouldn't touch the disk, and the file storage lives in storage/.
package world

import "core:mem"

Storage_Error :: enum {
	None,
	Io,
	Corrupt,
}

Storage :: struct {
	data:    rawptr,
	// Loads a chunk into `c` (uninitialized on entry). `found` is false when
	// the storage has no such chunk, which isn't an error.
	load:    proc(
		data: rawptr,
		pos: Chunk_Pos,
		c: ^Chunk,
		allocator: mem.Allocator,
	) -> (
		found: bool,
		err: Storage_Error,
	),
	save:    proc(data: rawptr, c: ^Chunk) -> Storage_Error,
	destroy: proc(data: rawptr),
}

storage_load :: proc(
	s: Storage,
	pos: Chunk_Pos,
	c: ^Chunk,
	allocator := context.allocator,
) -> (
	found: bool,
	err: Storage_Error,
) {
	if s.load == nil {
		return false, .None
	}
	return s.load(s.data, pos, c, allocator)
}

storage_save :: proc(s: Storage, c: ^Chunk) -> Storage_Error {
	if s.save == nil {
		return .None
	}
	return s.save(s.data, c)
}

storage_destroy :: proc(s: Storage) {
	if s.destroy != nil {
		s.destroy(s.data)
	}
}

// Keeps encoded chunks in a map. Nothing survives the process.
Memory_Storage :: struct {
	chunks:    map[Chunk_Pos][]u8,
	allocator: mem.Allocator,
}

memory_storage_init :: proc(m: ^Memory_Storage, allocator := context.allocator) {
	m.chunks = make(map[Chunk_Pos][]u8, allocator)
	m.allocator = allocator
}

memory_storage :: proc(m: ^Memory_Storage) -> Storage {
	return Storage{data = m, load = memory_load, save = memory_save, destroy = memory_destroy}
}

@(private = "file")
memory_load :: proc(
	data: rawptr,
	pos: Chunk_Pos,
	c: ^Chunk,
	allocator: mem.Allocator,
) -> (
	found: bool,
	err: Storage_Error,
) {
	m := (^Memory_Storage)(data)
	bytes, ok := m.chunks[pos]
	if !ok {
		return false, .None
	}
	decoded, derr := chunk_decode(bytes, allocator)
	if derr != .None {
		return true, .Corrupt
	}
	c^ = decoded
	return true, .None
}

@(private = "file")
memory_save :: proc(data: rawptr, c: ^Chunk) -> Storage_Error {
	m := (^Memory_Storage)(data)
	buf := make([dynamic]u8, 0, 256, m.allocator)
	chunk_encode(c, &buf)
	if old, ok := m.chunks[c.pos]; ok {
		delete(old, m.allocator)
	}
	m.chunks[c.pos] = buf[:]
	return .None
}

@(private = "file")
memory_destroy :: proc(data: rawptr) {
	m := (^Memory_Storage)(data)
	for _, bytes in m.chunks {
		delete(bytes, m.allocator)
	}
	delete(m.chunks)
}
