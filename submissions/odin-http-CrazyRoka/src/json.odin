package main

import "base:runtime"

import "core:strconv"

Json :: struct {
	b: [dynamic]byte,
}

json_init :: proc(capacity: int) -> Json {
	return Json{b = make([dynamic]byte, 0, capacity, runtime.heap_allocator())}
}

json_destroy :: proc(j: ^Json) {
	delete(j.b)
	j.b = nil
}

json_bytes :: proc(j: ^Json) -> []byte {
	return j.b[:]
}

json_raw :: proc(j: ^Json, s: string) {
	append(&j.b, ..transmute([]byte)s)
}

json_byte :: proc(j: ^Json, b: byte) {
	append(&j.b, b)
}

json_comma :: proc(j: ^Json, first: ^bool) {
	if first^ {
		first^ = false
	} else {
		append(&j.b, ',')
	}
}

json_key :: proc(j: ^Json, first: ^bool, key: string) {
	json_comma(j, first)
	json_str(j, key)
	append(&j.b, ':')
}

json_str :: proc(j: ^Json, s: string) {
	bytes := transmute([]byte)s
	append(&j.b, '"')
	start := 0
	for i := 0; i < len(bytes); i += 1 {
		c := bytes[i]
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		if start < i {
			append(&j.b, ..bytes[start:i])
		}
		switch c {
		case '"':
			append(&j.b, '\\', '"')
		case '\\':
			append(&j.b, '\\', '\\')
		case '\b':
			append(&j.b, '\\', 'b')
		case '\f':
			append(&j.b, '\\', 'f')
		case '\n':
			append(&j.b, '\\', 'n')
		case '\r':
			append(&j.b, '\\', 'r')
		case '\t':
			append(&j.b, '\\', 't')
		case:
			hex := "0123456789abcdef"
			append(&j.b, '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf])
		}
		start = i + 1
	}
	if start < len(bytes) {
		append(&j.b, ..bytes[start:])
	}
	append(&j.b, '"')
}

json_i64 :: proc(j: ^Json, n: i64) {
	buf: [32]byte
	s := strconv.write_int(buf[:], n, 10)
	json_raw(j, s)
}

json_bool :: proc(j: ^Json, v: bool) {
	json_raw(j, "true" if v else "false")
}

json_null :: proc(j: ^Json) {
	json_raw(j, "null")
}

json_obj_begin :: proc(j: ^Json) {
	append(&j.b, '{')
}

json_obj_end :: proc(j: ^Json) {
	append(&j.b, '}')
}

json_arr_begin :: proc(j: ^Json) {
	append(&j.b, '[')
}

json_arr_end :: proc(j: ^Json) {
	append(&j.b, ']')
}
