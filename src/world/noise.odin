// Deterministic noise for world generation. Everything is integer hashing
// plus f32 adds and multiplies, so the same seed gives the same bytes on
// every platform. No transcendental functions: their results differ between
// math libraries.
package world

// A 64-bit mix (splitmix64's finalizer) over the seed and coordinates.
hash3 :: proc "contextless" (seed: u64, x, y, z: i32) -> u64 {
	h := seed ~ (u64(u32(x)) * 0x9E3779B97F4A7C15)
	h = (h ~ (u64(u32(y)) * 0xBF58476D1CE4E5B9)) * 0x94D049BB133111EB
	h ~= u64(u32(z)) * 0xD6E8FEB86659FD93
	h ~= h >> 30
	h *= 0xBF58476D1CE4E5B9
	h ~= h >> 27
	h *= 0x94D049BB133111EB
	h ~= h >> 31
	return h
}

// A lattice value in [0, 1).
lattice :: proc "contextless" (seed: u64, x, y, z: i32) -> f32 {
	return f32(hash3(seed, x, y, z) >> 40) * (1.0 / 16777216.0)
}

@(private = "file")
smooth :: proc "contextless" (t: f32) -> f32 {
	return t * t * (3 - 2 * t)
}

@(private = "file")
floor_f :: proc "contextless" (v: f32) -> (i: i32, frac: f32) {
	i = i32(v)
	if f32(i) > v {
		i -= 1
	}
	frac = v - f32(i)
	return
}

// Smoothed 2D value noise in [0, 1).
value_noise_2d :: proc "contextless" (seed: u64, x, z: f32) -> f32 {
	xi, xf := floor_f(x)
	zi, zf := floor_f(z)
	u := smooth(xf)
	v := smooth(zf)
	a := lattice(seed, xi, 0, zi)
	b := lattice(seed, xi + 1, 0, zi)
	c := lattice(seed, xi, 0, zi + 1)
	d := lattice(seed, xi + 1, 0, zi + 1)
	top := a + (b - a) * u
	bottom := c + (d - c) * u
	return top + (bottom - top) * v
}

// Several octaves of value noise, normalized to [0, 1).
fbm_2d :: proc "contextless" (seed: u64, x, z: f32, octaves: int, lacunarity, gain: f32) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	freq: f32 = 1
	for i in 0 ..< octaves {
		sum += amp * value_noise_2d(seed + u64(i) * 0x51ED27, x * freq, z * freq)
		norm += amp
		amp *= gain
		freq *= lacunarity
	}
	return sum / norm
}
