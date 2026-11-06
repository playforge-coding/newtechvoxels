// Meshing: turning a chunk into the faces to draw. The GPU does this in
// shaders/mesh.wgsl; this package holds the face format both sides share,
// the occupancy bitmasks, the exact face count (so the CPU can size each
// chunk's range in the face buffer without reading anything back), and the
// CPU reference mesher the GPU one is tested against.
//
// A face is one voxel side: its position in the chunk, its normal, the
// ambient occlusion of its four corners and the block it belongs to.
package mesh

import "base:intrinsics"

import "../world"

// Mirrored by `Face` in shaders/mesh.wgsl.
Face :: struct {
	// x:5 | y:5 | z:5 | normal:3 | ao:8 (four corners, 2 bits each)
	a: u32,
	// block id:16
	b: u32,
}
#assert(size_of(Face) == 8)

// Normal indices, in the order the shaders use: +x -x +y -y +z -z.
Normal :: enum u8 {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

@(rodata)
NORMAL_DIR := [Normal][3]int {
	.Pos_X = {1, 0, 0},
	.Neg_X = {-1, 0, 0},
	.Pos_Y = {0, 1, 0},
	.Neg_Y = {0, -1, 0},
	.Pos_Z = {0, 0, 1},
	.Neg_Z = {0, 0, -1},
}

// The two tangent axes of each face, by normal axis: x faces span y and z,
// y faces x and z, z faces x and y. Corner i of a face is at
// (i & 1) along the first tangent and (i >> 1) along the second.
@(rodata)
TANGENTS := [Normal][2][3]int {
	.Pos_X = {{0, 1, 0}, {0, 0, 1}},
	.Neg_X = {{0, 1, 0}, {0, 0, 1}},
	.Pos_Y = {{1, 0, 0}, {0, 0, 1}},
	.Neg_Y = {{1, 0, 0}, {0, 0, 1}},
	.Pos_Z = {{1, 0, 0}, {0, 1, 0}},
	.Neg_Z = {{1, 0, 0}, {0, 1, 0}},
}

face_pack :: proc "contextless" (x, y, z: int, n: Normal, ao: u8, id: world.Block_Id) -> Face {
	return Face {
		a = u32(x) | u32(y) << 5 | u32(z) << 10 | u32(n) << 15 | u32(ao) << 18,
		b = u32(id),
	}
}

face_unpack :: proc "contextless" (
	f: Face,
) -> (
	x, y, z: int,
	n: Normal,
	ao: u8,
	id: world.Block_Id,
) {
	x = int(f.a & 31)
	y = int(f.a >> 5 & 31)
	z = int(f.a >> 10 & 31)
	n = Normal(f.a >> 15 & 7)
	ao = u8(f.a >> 18 & 0xFF)
	id = world.Block_Id(f.b & 0xFFFF)
	return
}

// One bit per voxel, set when the block is solid. Row (y, z) is at index
// y*CHUNK_SIZE + z, and bit x is voxel x.
Occupancy :: [world.CHUNK_AREA]u32

// Fills an occupancy mask from a chunk and the registry that says which
// blocks are solid.
occupancy :: proc(c: ^world.Chunk, reg: ^world.Registry, out: ^Occupancy) {
	solid := make([]bool, len(c.palette), context.temp_allocator)
	any_solid := false
	for id, i in c.palette {
		solid[i] = world.is_solid(reg, id)
		any_solid ||= solid[i]
	}
	if !any_solid {
		out^ = {}
		return
	}
	if c.bits == 0 {
		for &row in out {
			row = max(u32)
		}
		return
	}
	for y in 0 ..< world.CHUNK_SIZE {
		for z in 0 ..< world.CHUNK_SIZE {
			row: u32
			base := world.voxel_index(0, y, z)
			for x in 0 ..< world.CHUNK_SIZE {
				if solid[world.palette_slot(c, base + x)] {
					row |= 1 << u32(x)
				}
			}
			out[y * world.CHUNK_SIZE + z] = row
		}
	}
}

// The chunk being meshed and its six face neighbors. A nil neighbor is air,
// so faces at that border get drawn (and the chunk is re-meshed when the
// neighbor arrives).
Neighborhood :: struct {
	center: ^Occupancy,
	sides:  [Normal]^Occupancy,
}

// Whether the voxel at (x, y, z), which may be one step outside the chunk
// along at most one axis, is solid. Two axes out is beyond the six
// neighbors; it reads as air, on both the CPU and the GPU, so the meshers
// agree (ambient occlusion seams at chunk edges are the price).
solid_at :: proc "contextless" (n: Neighborhood, x, y, z: int) -> bool {
	out_x := x < 0 || x >= world.CHUNK_SIZE
	out_y := y < 0 || y >= world.CHUNK_SIZE
	out_z := z < 0 || z >= world.CHUNK_SIZE
	occ := n.center
	xx, yy, zz := x, y, z
	switch {
	case !out_x && !out_y && !out_z:
	case out_x && !out_y && !out_z:
		occ = n.sides[x < 0 ? .Neg_X : .Pos_X]
		xx = x & 31
	case out_y && !out_x && !out_z:
		occ = n.sides[y < 0 ? .Neg_Y : .Pos_Y]
		yy = y & 31
	case out_z && !out_x && !out_y:
		occ = n.sides[z < 0 ? .Neg_Z : .Pos_Z]
		zz = z & 31
	case:
		return false
	}
	if occ == nil {
		return false
	}
	return occ[yy * world.CHUNK_SIZE + zz] >> u32(xx) & 1 != 0
}

// The exact number of visible faces, from popcounts over the masks. This
// is what the GPU mesher will write for the same neighborhood.
count_faces :: proc "contextless" (n: Neighborhood) -> int {
	if n.center == nil {
		return 0
	}
	total := 0
	for y in 0 ..< world.CHUNK_SIZE {
		for z in 0 ..< world.CHUNK_SIZE {
			occ := n.center[y * world.CHUNK_SIZE + z]
			if occ == 0 {
				continue
			}
			// Along x within the row; the neighbor rows fill in bit 32 and
			// bit -1.
			right := occ >> 1
			if s := n.sides[.Pos_X]; s != nil {
				right |= (s[y * world.CHUNK_SIZE + z] & 1) << 31
			}
			left := occ << 1
			if s := n.sides[.Neg_X]; s != nil {
				left |= s[y * world.CHUNK_SIZE + z] >> 31
			}
			total += int(intrinsics.count_ones(occ & ~right))
			total += int(intrinsics.count_ones(occ & ~left))
			// Along y and z, the neighboring rows.
			total += int(intrinsics.count_ones(occ & ~row_at(n, y + 1, z)))
			total += int(intrinsics.count_ones(occ & ~row_at(n, y - 1, z)))
			total += int(intrinsics.count_ones(occ & ~row_at(n, y, z + 1)))
			total += int(intrinsics.count_ones(occ & ~row_at(n, y, z - 1)))
		}
	}
	return total
}

// The occupancy row at (y, z), one of which may be just outside the chunk.
@(private = "file")
row_at :: proc "contextless" (n: Neighborhood, y, z: int) -> u32 {
	occ := n.center
	yy, zz := y, z
	switch {
	case y < 0:
		occ = n.sides[.Neg_Y]
		yy = world.CHUNK_SIZE - 1
	case y >= world.CHUNK_SIZE:
		occ = n.sides[.Pos_Y]
		yy = 0
	case z < 0:
		occ = n.sides[.Neg_Z]
		zz = world.CHUNK_SIZE - 1
	case z >= world.CHUNK_SIZE:
		occ = n.sides[.Pos_Z]
		zz = 0
	}
	if occ == nil {
		return 0
	}
	return occ[yy * world.CHUNK_SIZE + zz]
}

// Ambient occlusion of one face: 2 bits per corner, 3 is open and 0 is a
// fully enclosed corner.
face_ao :: proc "contextless" (n: Neighborhood, x, y, z: int, normal: Normal) -> u8 {
	d := NORMAL_DIR[normal]
	t := TANGENTS[normal]
	px, py, pz := x + d.x, y + d.y, z + d.z
	ao: u8
	for corner in 0 ..< 4 {
		s1 := corner & 1 == 0 ? -1 : 1
		s2 := corner >> 1 == 0 ? -1 : 1
		a := solid_at(n, px + s1 * t[0].x, py + s1 * t[0].y, pz + s1 * t[0].z)
		b := solid_at(n, px + s2 * t[1].x, py + s2 * t[1].y, pz + s2 * t[1].z)
		c := solid_at(
			n,
			px + s1 * t[0].x + s2 * t[1].x,
			py + s1 * t[0].y + s2 * t[1].y,
			pz + s1 * t[0].z + s2 * t[1].z,
		)
		v: u8
		if a && b {
			v = 0
		} else {
			v = 3 - u8(int(a) + int(b) + int(c))
		}
		ao |= v << u8(corner * 2)
	}
	return ao
}

// The reference mesher. Appends every visible face of the chunk to `out`,
// in voxel order, in exactly the form the GPU mesher produces (apart from
// order).
build_faces :: proc(c: ^world.Chunk, n: Neighborhood, out: ^[dynamic]Face) {
	if n.center == nil {
		return
	}
	for y in 0 ..< world.CHUNK_SIZE {
		for z in 0 ..< world.CHUNK_SIZE {
			occ := n.center[y * world.CHUNK_SIZE + z]
			if occ == 0 {
				continue
			}
			for x in 0 ..< world.CHUNK_SIZE {
				if occ >> u32(x) & 1 == 0 {
					continue
				}
				id := world.chunk_get(c, x, y, z)
				for normal in Normal {
					d := NORMAL_DIR[normal]
					if solid_at(n, x + d.x, y + d.y, z + d.z) {
						continue
					}
					append(out, face_pack(x, y, z, normal, face_ao(n, x, y, z, normal), id))
				}
			}
		}
	}
}
