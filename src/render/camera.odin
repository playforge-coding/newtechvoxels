// Camera matrices and frustum culling. Right-handed, y up, and a depth
// range of 0..1 as WebGPU wants; core:math/linalg's perspective gives
// OpenGL's -1..1, so the projection is written out here.
package render

import "core:math"
import "core:math/linalg"

// Mirrors `Camera` in shaders/chunk.wgsl.
Camera_Uniform :: struct {
	view_proj: matrix[4, 4]f32,
	position:  [4]f32,
	sun:       [4]f32,
}
#assert(size_of(Camera_Uniform) == 96)

Camera :: struct {
	position:   [3]f32,
	yaw, pitch: f32,
	fov_y:      f32,
	near, far:  f32,
	aspect:     f32,
}

DEFAULT_CAMERA :: Camera {
	fov_y  = 75 * math.PI / 180,
	near   = 0.05,
	far    = 1000,
	aspect = 16.0 / 9.0,
}

camera_forward :: proc "contextless" (c: Camera) -> [3]f32 {
	cp := math.cos(c.pitch)
	return {math.sin(c.yaw) * cp, math.sin(c.pitch), math.cos(c.yaw) * cp}
}

// A perspective projection mapping the near plane to depth 0 and the far
// plane to 1.
perspective :: proc "contextless" (fov_y, aspect, near, far: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(fov_y / 2)
	m: matrix[4, 4]f32
	m[0, 0] = f / aspect
	m[1, 1] = f
	m[2, 2] = far / (near - far)
	m[2, 3] = near * far / (near - far)
	m[3, 2] = -1
	return m
}

view_matrix :: proc "contextless" (c: Camera) -> matrix[4, 4]f32 {
	return linalg.matrix4_look_at_f32(c.position, c.position + camera_forward(c), {0, 1, 0})
}

view_projection :: proc "contextless" (c: Camera) -> matrix[4, 4]f32 {
	return perspective(c.fov_y, c.aspect, c.near, c.far) * view_matrix(c)
}

// The six planes of a view-projection matrix as (normal, distance) with the
// inside on the positive side.
Frustum :: [6][4]f32

frustum_from :: proc "contextless" (m: matrix[4, 4]f32) -> (f: Frustum) {
	// Rows of the matrix.
	r0 := [4]f32{m[0, 0], m[0, 1], m[0, 2], m[0, 3]}
	r1 := [4]f32{m[1, 0], m[1, 1], m[1, 2], m[1, 3]}
	r2 := [4]f32{m[2, 0], m[2, 1], m[2, 2], m[2, 3]}
	r3 := [4]f32{m[3, 0], m[3, 1], m[3, 2], m[3, 3]}
	f[0] = r3 + r0 // left
	f[1] = r3 - r0 // right
	f[2] = r3 + r1 // bottom
	f[3] = r3 - r1 // top
	f[4] = r2 // near (depth 0..1)
	f[5] = r3 - r2 // far
	return
}

// Whether a box intersects or is inside the frustum.
frustum_sees_box :: proc "contextless" (f: Frustum, lo, hi: [3]f32) -> bool {
	for p in f {
		// The corner furthest along the plane normal.
		x := p.x >= 0 ? hi.x : lo.x
		y := p.y >= 0 ? hi.y : lo.y
		z := p.z >= 0 ? hi.z : lo.z
		if p.x * x + p.y * y + p.z * z + p.w < 0 {
			return false
		}
	}
	return true
}
