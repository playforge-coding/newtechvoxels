// Measurement. Every frame appends a row of timings and counters; at the
// end the rows go to a CSV and the frame times to a summary with
// percentiles, since averages hide the stutter the research question is
// about. Nothing here is specific to a scene.
package telemetry

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Row :: struct {
	// Seconds since recording started.
	time:            f64,
	frame_ms:        f64,
	// CPU time of the simulation ticks run this frame.
	tick_ms:         f64,
	ticks:           int,
	chunks_meshed:   int,
	chunks_drawn:    int,
	faces_drawn:     int,
	chunks_uploaded: int,
	chunks_loaded:   int,
	chunks_received: int,
	bytes_received:  int,
	bytes_sent:      int,
	// Bytes the game has allocated through the tracking allocator, when
	// one is in use; 0 otherwise.
	memory_bytes:    int,
}

Recorder :: struct {
	rows: [dynamic]Row,
}

recorder_init :: proc(r: ^Recorder, allocator := context.allocator) {
	r.rows = make([dynamic]Row, 0, 4096, allocator)
}

recorder_destroy :: proc(r: ^Recorder) {
	delete(r.rows)
}

record :: proc(r: ^Recorder, row: Row) {
	append(&r.rows, row)
}

Summary :: struct {
	frames:     int,
	seconds:    f64,
	average_ms: f64,
	p50_ms:     f64,
	p99_ms:     f64,
	// The mean of the slowest 1% and 0.1% of frames, the usual "1% low"
	// and "0.1% low" figures (as frame times, so higher is worse).
	low_1_ms:   f64,
	low_01_ms:  f64,
	max_ms:     f64,
}

summarize :: proc(r: ^Recorder) -> (s: Summary) {
	n := len(r.rows)
	if n == 0 {
		return
	}
	times := make([]f64, n, context.temp_allocator)
	total: f64
	for row, i in r.rows {
		times[i] = row.frame_ms
		total += row.frame_ms
	}
	slice.sort(times)
	s.frames = n
	s.seconds = r.rows[n - 1].time - r.rows[0].time
	s.average_ms = total / f64(n)
	s.p50_ms = times[n / 2]
	s.p99_ms = times[min(n - 1, n * 99 / 100)]
	s.max_ms = times[n - 1]
	s.low_1_ms = mean_of_tail(times, max(1, n / 100))
	s.low_01_ms = mean_of_tail(times, max(1, n / 1000))
	return
}

@(private = "file")
mean_of_tail :: proc(sorted: []f64, count: int) -> f64 {
	sum: f64
	for v in sorted[len(sorted) - count:] {
		sum += v
	}
	return sum / f64(count)
}

format_summary :: proc(s: Summary, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%d frames in %.1fs: avg %.2f ms, p50 %.2f, p99 %.2f, 1%% low %.2f, 0.1%% low %.2f, max %.2f",
		s.frames,
		s.seconds,
		s.average_ms,
		s.p50_ms,
		s.p99_ms,
		s.low_1_ms,
		s.low_01_ms,
		s.max_ms,
		allocator = allocator,
	)
}

// Writes every row as CSV with a header.
write_csv :: proc(r: ^Recorder, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"time,frame_ms,tick_ms,ticks,chunks_meshed,chunks_drawn,faces_drawn,chunks_uploaded,chunks_loaded,chunks_received,bytes_received,bytes_sent,memory_bytes\n",
	)
	for row in r.rows {
		fmt.sbprintf(
			&b,
			"%.4f,%.4f,%.4f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
			row.time,
			row.frame_ms,
			row.tick_ms,
			row.ticks,
			row.chunks_meshed,
			row.chunks_drawn,
			row.faces_drawn,
			row.chunks_uploaded,
			row.chunks_loaded,
			row.chunks_received,
			row.bytes_received,
			row.bytes_sent,
			row.memory_bytes,
		)
	}
	return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}
