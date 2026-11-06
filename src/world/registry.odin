// The block registry: what each block id means. Built-in content and, later,
// mods register through the same procedure, so there is one path for both.
package world

Block_Def :: struct {
	// A unique name like "stone". Built-in names have no prefix; mods will
	// use "mod:name".
	name:  string,
	// Blocks that stop movement and hide the faces behind them. Everything
	// the MVP has is either solid or air.
	solid: bool,
	// The flat color the renderer uses until there are textures, sRGB.
	color: [3]u8,
}

Registry :: struct {
	defs: [dynamic]Block_Def,
}

registry_init :: proc(r: ^Registry, allocator := context.allocator) {
	r.defs = make([dynamic]Block_Def, 0, 64, allocator)
	// Id 0 is air, always.
	append(&r.defs, Block_Def{name = "air"})
}

registry_destroy :: proc(r: ^Registry) {
	delete(r.defs)
}

// Adds a block and returns its id. Ids are dense and given in registration
// order, so built-in blocks have to be registered in a fixed order (see
// register_builtin_blocks) for saves and sessions to agree.
registry_add :: proc(r: ^Registry, def: Block_Def) -> Block_Id {
	append(&r.defs, def)
	return Block_Id(len(r.defs) - 1)
}

// The definition of a block. Unknown ids read as air rather than crashing,
// since ids come from saves and the network.
block_def :: proc "contextless" (r: ^Registry, id: Block_Id) -> Block_Def {
	if int(id) >= len(r.defs) {
		return r.defs[0]
	}
	return r.defs[int(id)]
}

is_solid :: proc "contextless" (r: ^Registry, id: Block_Id) -> bool {
	return int(id) < len(r.defs) && r.defs[int(id)].solid
}

block_by_name :: proc(r: ^Registry, name: string) -> (Block_Id, bool) {
	for d, i in r.defs {
		if d.name == name {
			return Block_Id(i), true
		}
	}
	return AIR, false
}

// The built-in blocks, in the order that fixes their ids.
Builtin :: enum Block_Id {
	Air,
	Stone,
	Dirt,
	Grass,
	Sand,
	Snow,
	Log,
	Leaves,
	Water,
	Gravel,
	Brick,
}

register_builtin_blocks :: proc(r: ^Registry) {
	defs := [Builtin]Block_Def {
		.Air = {name = "air"},
		.Stone = {name = "stone", solid = true, color = {0x7a, 0x7a, 0x7a}},
		.Dirt = {name = "dirt", solid = true, color = {0x7a, 0x55, 0x36}},
		.Grass = {name = "grass", solid = true, color = {0x5c, 0x9e, 0x3d}},
		.Sand = {name = "sand", solid = true, color = {0xd9, 0xcb, 0x8f}},
		.Snow = {name = "snow", solid = true, color = {0xf2, 0xf4, 0xf7}},
		.Log = {name = "log", solid = true, color = {0x5b, 0x40, 0x27}},
		.Leaves = {name = "leaves", solid = true, color = {0x3f, 0x7f, 0x30}},
		.Water = {name = "water", solid = true, color = {0x2f, 0x6f, 0xb5}},
		.Gravel = {name = "gravel", solid = true, color = {0x66, 0x64, 0x61}},
		.Brick = {name = "brick", solid = true, color = {0x9c, 0x4a, 0x3a}},
	}
	for b in Builtin {
		if b == .Air {
			continue
		}
		id := registry_add(r, defs[b])
		assert(id == Block_Id(b), "built-in block ids must match the Builtin enum")
	}
}
