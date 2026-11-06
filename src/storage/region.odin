// Chunk persistence in region files: each file holds the chunks of an
// 8x8x8 block of the chunk grid as Zstandard frames of the chunk's wire
// format, behind a table of offsets and lengths. Writes append and update
// the table; space from overwritten chunks is reclaimed by a rewrite, not
// yet done (see the roadmap).
//
// Everything read from a file is checked before use: a corrupt table entry
// or frame gives Storage_Error.Corrupt, never a crash.
package storage

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"

import "sdk:zstd"

import "../world"

REGION_SIZE :: 8
REGION_CHUNKS :: REGION_SIZE * REGION_SIZE * REGION_SIZE
MAGIC :: "NTVR"
VERSION :: 1
HEADER_SIZE :: 8 + REGION_CHUNKS * 8
// The largest frame a chunk may decompress to.
MAX_CHUNK_BYTES :: world.CHUNK_VOLUME * 2 + world.MAX_PALETTE * 2 + 64

Region_Pos :: distinct [3]i32

File_Storage :: struct {
	dir:       string,
	allocator: mem.Allocator,
	level:     int,
}

// Opens (creating if needed) the save directory.
file_storage_init :: proc(
	fs: ^File_Storage,
	dir: string,
	level := zstd.DEFAULT_LEVEL,
	allocator := context.allocator,
) -> world.Storage_Error {
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		return .Io
	}
	fs.dir = clone(dir, allocator)
	fs.allocator = allocator
	fs.level = level
	return .None
}

file_storage :: proc(fs: ^File_Storage) -> world.Storage {
	return world.Storage{data = fs, load = file_load, save = file_save, destroy = file_destroy}
}

region_of :: proc "contextless" (p: world.Chunk_Pos) -> (r: Region_Pos, index: int) {
	r = Region_Pos{p.x >> 3, p.y >> 3, p.z >> 3}
	lx := int(p.x & 7)
	ly := int(p.y & 7)
	lz := int(p.z & 7)
	index = (ly * REGION_SIZE + lz) * REGION_SIZE + lx
	return
}

@(private = "file")
region_path :: proc(fs: ^File_Storage, r: Region_Pos, allocator: mem.Allocator) -> string {
	name := fmt.tprintf("r.%d.%d.%d.ntvr", r.x, r.y, r.z)
	path, _ := filepath.join({fs.dir, name}, allocator)
	return path
}

// The offset table: 0 length means no chunk.
@(private = "file")
Entry :: struct {
	offset: u32,
	length: u32,
}

@(private = "file")
read_table :: proc(f: ^os.File, table: ^[REGION_CHUNKS]Entry) -> world.Storage_Error {
	header: [HEADER_SIZE]u8
	n, err := os.read_at(f, header[:], 0)
	if err != nil || n != HEADER_SIZE {
		return .Corrupt
	}
	if string(header[:4]) != MAGIC {
		return .Corrupt
	}
	version := u32(header[4]) | u32(header[5]) << 8 | u32(header[6]) << 16 | u32(header[7]) << 24
	if version != VERSION {
		return .Corrupt
	}
	for i in 0 ..< REGION_CHUNKS {
		b := header[8 + i * 8:]
		table[i] = Entry {
			offset = u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24,
			length = u32(b[4]) | u32(b[5]) << 8 | u32(b[6]) << 16 | u32(b[7]) << 24,
		}
	}
	return .None
}

@(private = "file")
write_entry :: proc(f: ^os.File, index: int, e: Entry) -> world.Storage_Error {
	b: [8]u8
	b[0], b[1], b[2], b[3] =
		u8(e.offset), u8(e.offset >> 8), u8(e.offset >> 16), u8(e.offset >> 24)
	b[4], b[5], b[6], b[7] =
		u8(e.length), u8(e.length >> 8), u8(e.length >> 16), u8(e.length >> 24)
	n, err := os.write_at(f, b[:], i64(8 + index * 8))
	if err != nil || n != 8 {
		return .Io
	}
	return .None
}

@(private = "file")
write_fresh_header :: proc(f: ^os.File) -> world.Storage_Error {
	header: [HEADER_SIZE]u8
	copy(header[:4], MAGIC)
	header[4] = VERSION
	n, err := os.write_at(f, header[:], 0)
	if err != nil || n != HEADER_SIZE {
		return .Io
	}
	return .None
}

@(private = "file")
file_load :: proc(
	data: rawptr,
	pos: world.Chunk_Pos,
	c: ^world.Chunk,
	allocator: mem.Allocator,
) -> (
	found: bool,
	err: world.Storage_Error,
) {
	fs := (^File_Storage)(data)
	r, index := region_of(pos)
	path := region_path(fs, r, context.temp_allocator)
	if !os.exists(path) {
		return false, .None
	}
	f, oerr := os.open(path)
	if oerr != nil {
		return false, .Io
	}
	defer os.close(f)
	table: [REGION_CHUNKS]Entry
	if terr := read_table(f, &table); terr != .None {
		return false, terr
	}
	e := table[index]
	if e.length == 0 {
		return false, .None
	}
	size, serr := os.file_size(f)
	if serr != nil || i64(e.offset) < HEADER_SIZE || i64(e.offset) + i64(e.length) > size {
		return true, .Corrupt
	}
	frame := make([]u8, int(e.length), context.temp_allocator)
	n, rerr := os.read_at(f, frame, i64(e.offset))
	if rerr != nil || n != len(frame) {
		return true, .Io
	}
	raw, zerr := zstd.decompress_slice(frame, MAX_CHUNK_BYTES, context.temp_allocator)
	if zerr != .None {
		return true, .Corrupt
	}
	decoded, derr := world.chunk_decode(raw, allocator)
	if derr != .None || decoded.pos != pos {
		if derr == .None {
			world.chunk_destroy(&decoded)
		}
		return true, .Corrupt
	}
	c^ = decoded
	return true, .None
}

@(private = "file")
file_save :: proc(data: rawptr, c: ^world.Chunk) -> world.Storage_Error {
	fs := (^File_Storage)(data)
	r, index := region_of(c.pos)
	path := region_path(fs, r, context.temp_allocator)

	raw := make([dynamic]u8, 0, 4096, context.temp_allocator)
	world.chunk_encode(c, &raw)
	frame, zerr := zstd.compress_slice(raw[:], fs.level, context.temp_allocator)
	if zerr != .None {
		return .Io
	}

	fresh := !os.exists(path)
	f, oerr := os.open(path, {.Read, .Write, .Create})
	if oerr != nil {
		return .Io
	}
	defer os.close(f)
	if fresh {
		if herr := write_fresh_header(f); herr != .None {
			return herr
		}
	} else {
		table: [REGION_CHUNKS]Entry
		if terr := read_table(f, &table); terr != .None {
			return terr
		}
	}
	size, serr := os.file_size(f)
	if serr != nil || size < HEADER_SIZE {
		return .Corrupt
	}
	n, werr := os.write_at(f, frame, size)
	if werr != nil || n != len(frame) {
		return .Io
	}
	return write_entry(f, index, Entry{offset = u32(size), length = u32(len(frame))})
}

@(private = "file")
file_destroy :: proc(data: rawptr) {
	fs := (^File_Storage)(data)
	delete(fs.dir, fs.allocator)
}

@(private = "file")
clone :: proc(s: string, allocator: mem.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
