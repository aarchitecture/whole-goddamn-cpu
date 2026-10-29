package main

import "base:runtime"

import "core:crypto"
import "core:strings"

foreign import libcrypt "system:crypt"

foreign libcrypt {
	crypt_gensalt_rn :: proc(prefix: cstring, count: u64, rbytes: [^]byte, nrbytes: i32, output: [^]byte, output_size: i32) -> cstring ---
	crypt_rn :: proc(phrase: cstring, setting: cstring, data: rawptr, size: i32) -> cstring ---
}

BCRYPT_PREFIX :: cstring("$2b$")
BCRYPT_COST :: u64(10)
CRYPT_DATA_SIZE :: 32768
CRYPT_SALT_SIZE :: 192

hash_password :: proc(password: string, scratch: []byte, allocator := context.temp_allocator) -> (hash: string, ok: bool) {
	if len(password) > 72 {
		return "", false
	}

	phrase := strings.clone_to_cstring(password, allocator)
	random: [16]byte
	crypto.rand_bytes(random[:])

	salt_buf: [CRYPT_SALT_SIZE]byte
	salt := crypt_gensalt_rn(
		BCRYPT_PREFIX,
		BCRYPT_COST,
		&random[0],
		i32(len(random)),
		&salt_buf[0],
		i32(len(salt_buf)),
	)
	if salt == nil {
		return "", false
	}

	data := scratch
	if len(data) < CRYPT_DATA_SIZE {
		data = make([]byte, CRYPT_DATA_SIZE, allocator)
	}
	out := crypt_rn(phrase, salt, raw_data(data), i32(len(data)))
	if out == nil {
		return "", false
	}

	hash = runtime.cstring_to_string(out)
	if len(hash) < 20 || hash[0] != '$' {
		return "", false
	}
	return strings.clone(hash, allocator), true
}

verify_password :: proc(password, hash: string, scratch: []byte, allocator := context.temp_allocator) -> bool {
	if len(password) > 72 {
		return false
	}

	phrase := strings.clone_to_cstring(password, allocator)
	setting := strings.clone_to_cstring(hash, allocator)
	data := scratch
	if len(data) < CRYPT_DATA_SIZE {
		data = make([]byte, CRYPT_DATA_SIZE, allocator)
	}
	out := crypt_rn(phrase, setting, raw_data(data), i32(len(data)))
	if out == nil {
		return false
	}

	computed := runtime.cstring_to_string(out)
	if len(computed) != len(hash) {
		return false
	}
	return crypto.compare_constant_time(transmute([]byte)computed, transmute([]byte)hash) == 1
}
