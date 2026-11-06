// Bindings to libzstd, only what the game calls: one-shot compression and
// decompression of a buffer. Links the system library (libzstd-dev on
// Debian and Ubuntu, zstd from Homebrew, the zstd package from vcpkg on
// Windows).
//
// BSD-3-Clause, like everything under sdk/.
package zstd

import "core:c"
import "core:mem"

when ODIN_OS == .Windows {
	foreign import lib "system:zstd.lib"
} else {
	foreign import lib "system:zstd"
}

CONTENTSIZE_UNKNOWN :: max(c.ulonglong)
CONTENTSIZE_ERROR :: max(c.ulonglong) - 1

@(default_calling_convention = "c", link_prefix = "ZSTD_")
foreign lib {
	compressBound :: proc(src_size: c.size_t) -> c.size_t ---
	compress :: proc(dst: rawptr, dst_capacity: c.size_t, src: rawptr, src_size: c.size_t, level: c.int) -> c.size_t ---
	decompress :: proc(dst: rawptr, dst_capacity: c.size_t, src: rawptr, compressed_size: c.size_t) -> c.size_t ---
	getFrameContentSize :: proc(src: rawptr, src_size: c.size_t) -> c.ulonglong ---
	isError :: proc(code: c.size_t) -> c.uint ---
	getErrorName :: proc(code: c.size_t) -> cstring ---
	minCLevel :: proc() -> c.int ---
	maxCLevel :: proc() -> c.int ---
	versionNumber :: proc() -> c.uint ---
}

Error :: enum {
	None,
	// libzstd reported a failure; `error_name` has its message.
	Library,
	// The frame doesn't say how big it decompresses to, or says more than
	// the caller allows.
	Size_Unknown,
	Too_Large,
	// The frame decompressed to a different size than it claimed.
	Size_Mismatch,
	Allocation,
}

// The default level, a good trade between size and speed for chunk saves.
DEFAULT_LEVEL :: 3

// Compresses `src` into a new buffer from `allocator`.
compress_slice :: proc(
	src: []u8,
	level := DEFAULT_LEVEL,
	allocator := context.allocator,
) -> (
	out: []u8,
	err: Error,
) {
	bound := compressBound(c.size_t(len(src)))
	buf, aerr := make([]u8, int(bound), allocator)
	if aerr != nil {
		return nil, .Allocation
	}
	n := compress(raw_data(buf), bound, raw_data(src), c.size_t(len(src)), c.int(level))
	if isError(n) != 0 {
		delete(buf, allocator)
		return nil, .Library
	}
	// Give back the slack; the caller frees `out` with the same allocator.
	if int(n) < len(buf) {
		shrunk, rerr := mem.resize_bytes(buf, int(n), 1, allocator)
		if rerr == nil {
			return shrunk, .None
		}
	}
	return buf[:n], .None
}

// Decompresses a frame that declares its content size, refusing anything
// larger than `max_size`, so a few bytes can't turn into gigabytes.
decompress_slice :: proc(
	src: []u8,
	max_size: int,
	allocator := context.allocator,
) -> (
	out: []u8,
	err: Error,
) {
	size := getFrameContentSize(raw_data(src), c.size_t(len(src)))
	if size == CONTENTSIZE_UNKNOWN || size == CONTENTSIZE_ERROR {
		return nil, .Size_Unknown
	}
	if size > c.ulonglong(max_size) {
		return nil, .Too_Large
	}
	buf, aerr := make([]u8, int(size), allocator)
	if aerr != nil {
		return nil, .Allocation
	}
	n := decompress(raw_data(buf), c.size_t(size), raw_data(src), c.size_t(len(src)))
	if isError(n) != 0 {
		delete(buf, allocator)
		return nil, .Library
	}
	if n != c.size_t(size) {
		delete(buf, allocator)
		return nil, .Size_Mismatch
	}
	return buf, .None
}

// The library's message for a failed call's return value.
error_name :: proc(code: c.size_t) -> string {
	return string(getErrorName(code))
}
