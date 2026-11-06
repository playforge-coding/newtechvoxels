// Fetches the wgpu-native library that vendor:wgpu links, into Odin's own
// vendor directory, which is where the binding looks for it (see
// vendor/wgpu/doc.odin). Run through `just setup`, once per machine or
// Odin version. Needs curl and unzip (tar on Windows) on the path.
package setup

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The version vendor:wgpu is written against; check vendor/wgpu/wgpu.odin
// when bumping Odin.
WGPU_NATIVE_VERSION :: "v29.0.1.1"

main :: proc() {
	root := odin_root()
	if root == "" {
		fmt.eprintln("could not find the Odin root (is odin on the path?)")
		os.exit(1)
	}
	name := release_name()
	if name == "" {
		fmt.eprintln("no wgpu-native release for this platform")
		os.exit(1)
	}
	lib_dir, _ := filepath.join({root, "vendor", "wgpu", "lib"}, context.temp_allocator)
	target, _ := filepath.join({lib_dir, name}, context.temp_allocator)
	if os.exists(target) {
		fmt.printfln("wgpu-native already at %s", target)
		return
	}
	url := fmt.tprintf(
		"https://github.com/gfx-rs/wgpu-native/releases/download/%s/%s.zip",
		WGPU_NATIVE_VERSION,
		name,
	)
	zip, _ := filepath.join({lib_dir, fmt.tprintf("%s.zip", name)}, context.temp_allocator)
	os.make_directory_all(lib_dir)
	fmt.printfln("downloading %s", url)
	run({"curl", "-sSfL", "-o", zip, url})
	os.make_directory_all(target)
	extract(zip, target)
	os.remove(zip)
	fmt.printfln("installed wgpu-native %s into %s", WGPU_NATIVE_VERSION, target)
}

release_name :: proc() -> string {
	arch := ""
	#partial switch ODIN_ARCH {
	case .amd64:
		arch = "x86_64"
	case .arm64:
		arch = "aarch64"
	case:
		return ""
	}
	#partial switch ODIN_OS {
	case .Linux:
		return fmt.tprintf("wgpu-linux-%s-release", arch)
	case .Darwin:
		return fmt.tprintf("wgpu-macos-%s-release", arch)
	case .Windows:
		return fmt.tprintf("wgpu-windows-%s-msvc-release", arch)
	case:
		return ""
	}
}

// Unpacks a zip with whatever the machine has: bsdtar (macOS and Windows
// ship it), unzip, or Python's zipfile module.
extract :: proc(zip, target: string) {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		run({"tar", "-xf", zip, "-C", target})
	} else {
		if try({"unzip", "-oq", zip, "-d", target}) {
			return
		}
		run({"python3", "-m", "zipfile", "-e", zip, target})
	}
}

odin_root :: proc() -> string {
	state, out, _, err := os.process_exec({command = {"odin", "root"}}, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		return ""
	}
	return strings.trim_space(string(out))
}

try :: proc(command: []string) -> bool {
	state, _, _, err := os.process_exec({command = command}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}

run :: proc(command: []string) {
	state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		fmt.eprintfln("%v failed: %s", command, string(stderr))
		os.exit(1)
	}
}
