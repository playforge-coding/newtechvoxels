// A range allocator for the big GPU buffers: chunks get a run of words in
// the voxel buffer and a run of faces in the face buffer, and give them
// back when they unload or re-mesh. First fit over a sorted free list with
// coalescing; sizes are in elements, not bytes.
package render

Range :: struct {
	offset, length: u32,
}

Range_Allocator :: struct {
	free:     [dynamic]Range,
	capacity: u32,
	used:     u32,
}

range_allocator_init :: proc(a: ^Range_Allocator, capacity: u32, allocator := context.allocator) {
	a.free = make([dynamic]Range, 0, 64, allocator)
	append(&a.free, Range{0, capacity})
	a.capacity = capacity
}

range_allocator_destroy :: proc(a: ^Range_Allocator) {
	delete(a.free)
}

// Takes `length` elements. A zero length succeeds with an empty range.
range_alloc :: proc(a: ^Range_Allocator, length: u32) -> (r: Range, ok: bool) {
	if length == 0 {
		return {}, true
	}
	for &f, i in a.free {
		if f.length < length {
			continue
		}
		r = Range{f.offset, length}
		f.offset += length
		f.length -= length
		if f.length == 0 {
			ordered_remove(&a.free, i)
		}
		a.used += length
		return r, true
	}
	return {}, false
}

// Gives a range back, merging it with free neighbors.
range_free :: proc(a: ^Range_Allocator, r: Range) {
	if r.length == 0 {
		return
	}
	a.used -= r.length
	// Find the first free range after r.
	i := 0
	for i < len(a.free) && a.free[i].offset < r.offset {
		i += 1
	}
	merged := r
	// Merge with the one after.
	if i < len(a.free) && merged.offset + merged.length == a.free[i].offset {
		merged.length += a.free[i].length
		ordered_remove(&a.free, i)
	}
	// Merge with the one before.
	if i > 0 && a.free[i - 1].offset + a.free[i - 1].length == merged.offset {
		a.free[i - 1].length += merged.length
		return
	}
	inject_at(&a.free, i, merged)
}
