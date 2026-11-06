// World generation. A generator fills a fresh chunk from its position; the
// world calls it for chunks that no storage has. The interface is a struct
// of procedures so a mod or a benchmark scene can plug in its own.
package world

Generator :: struct {
	data:     rawptr,
	// Fills `c`, which is initialized and empty, from its position.
	generate: proc(data: rawptr, c: ^Chunk),
}

// Rolling terrain from a heightmap: stone with dirt and grass on top, sand
// and water at sea level, snow on the peaks. Its parameters are
// configuration so benchmark scenes can match a baseline's world shape.
Terrain_Params :: struct {
	seed:       u64,
	sea_level:  i32,
	// The lowest and highest ground heights the noise maps to.
	min_height: i32,
	max_height: i32,
	// Blocks per noise cell; bigger is smoother.
	scale:      f32,
	octaves:    int,
	snow_above: i32,
}

DEFAULT_TERRAIN :: Terrain_Params {
	seed       = 1,
	sea_level  = 20,
	min_height = 4,
	max_height = 80,
	scale      = 96,
	octaves    = 5,
	snow_above = 64,
}

Terrain :: struct {
	params: Terrain_Params,
}

terrain_generator :: proc(t: ^Terrain) -> Generator {
	return Generator{data = t, generate = terrain_generate}
}

// The ground height at a world column.
terrain_height :: proc "contextless" (p: Terrain_Params, x, z: i32) -> i32 {
	n := fbm_2d(p.seed, f32(x) / p.scale, f32(z) / p.scale, p.octaves, 2.0, 0.5)
	// Square it so plains are common and mountains rare.
	n = n * n
	return p.min_height + i32(n * f32(p.max_height - p.min_height))
}

terrain_generate :: proc(data: rawptr, c: ^Chunk) {
	t := (^Terrain)(data)
	p := t.params
	origin := chunk_origin(c.pos)
	// Chunks entirely above the highest possible ground stay air (and
	// chunks fully below it are filled with stone) without touching voxels.
	if origin.y > max(p.max_height, p.sea_level) {
		return
	}
	if origin.y + CHUNK_SIZE <= p.min_height - 4 {
		chunk_fill(c, Block_Id(Builtin.Stone))
		return
	}
	heights: [CHUNK_AREA]i32
	for z in 0 ..< CHUNK_SIZE {
		for x in 0 ..< CHUNK_SIZE {
			heights[z * CHUNK_SIZE + x] = terrain_height(p, origin.x + i32(x), origin.z + i32(z))
		}
	}
	for z in 0 ..< CHUNK_SIZE {
		for x in 0 ..< CHUNK_SIZE {
			h := heights[z * CHUNK_SIZE + x]
			wx := origin.x + i32(x)
			wz := origin.z + i32(z)
			for y in 0 ..< CHUNK_SIZE {
				wy := origin.y + i32(y)
				id := AIR
				switch {
				case wy > h:
					if wy <= p.sea_level {
						id = Block_Id(Builtin.Water)
					}
				case wy == h:
					switch {
					case h >= p.snow_above:
						id = Block_Id(Builtin.Snow)
					case h <= p.sea_level + 1:
						id = Block_Id(Builtin.Sand)
					case:
						id = Block_Id(Builtin.Grass)
					}
				case wy > h - 4:
					id = h <= p.sea_level + 1 ? Block_Id(Builtin.Sand) : Block_Id(Builtin.Dirt)
				case:
					// A little gravel in the stone, from the hash so it's
					// deterministic.
					id =
						hash3(p.seed, wx, wy, wz) % 61 == 0 ? Block_Id(Builtin.Gravel) : Block_Id(Builtin.Stone)
				}
				if id != AIR {
					chunk_set(c, x, y, z, id)
				}
			}
		}
	}
}

// A flat world: one block type up to a height. For tests and for the
// benchmark scenes that need a known shape.
Flat :: struct {
	height: i32,
	block:  Block_Id,
}

flat_generator :: proc(f: ^Flat) -> Generator {
	return Generator{data = f, generate = flat_generate}
}

flat_generate :: proc(data: rawptr, c: ^Chunk) {
	f := (^Flat)(data)
	origin := chunk_origin(c.pos)
	if origin.y >= f.height {
		return
	}
	if origin.y + CHUNK_SIZE <= f.height {
		chunk_fill(c, f.block)
		return
	}
	top := int(f.height - origin.y)
	for y in 0 ..< top {
		for z in 0 ..< CHUNK_SIZE {
			for x in 0 ..< CHUNK_SIZE {
				chunk_set(c, x, y, z, f.block)
			}
		}
	}
}
