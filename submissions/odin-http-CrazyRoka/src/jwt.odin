package main

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

TOKEN_TTL :: i64(30 * 24 * 60 * 60)
JWT_HEADER :: `{"alg":"HS256","typ":"JWT"}`

Auth :: struct {
	viewer:  i64,
	token:   string,
	present: bool,
	valid:   bool,
}

parse_positive_id :: proc(s: string) -> (id: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	n: i64
	for c in transmute([]byte)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := i64(c - '0')
		if n > (max(i64) - d) / 10 {
			return 0, false
		}
		n = n * 10 + d
	}
	return n, n > 0
}

b64url_encode :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	encoded, err := base64.encode(data, base64.ENC_URL_TABLE, allocator)
	assert(err == .None)
	return strings.trim_right(encoded, "=")
}

issue_token :: proc(id: i64, secret: []byte, allocator := context.temp_allocator) -> string {
	now := time.to_unix_seconds(time.now())
	payload := fmt.tprintf(`{{"sub":"%d","iat":%d,"exp":%d}}`, id, now, now + TOKEN_TTL)
	header_str := JWT_HEADER
	header_enc := b64url_encode(transmute([]byte)header_str, allocator)
	payload_enc := b64url_encode(transmute([]byte)payload, allocator)
	signing_input := fmt.tprintf("%s.%s", header_enc, payload_enc)

	sig: [32]byte
	hmac.sum(.SHA256, sig[:], transmute([]byte)signing_input, secret)
	sig_enc := b64url_encode(sig[:], allocator)

	return fmt.tprintf("%s.%s", signing_input, sig_enc)
}

verify_token :: proc(token: string, secret: []byte, allocator := context.temp_allocator) -> (id: i64, ok: bool) {
	first_dot := strings.index_byte(token, '.')
	if first_dot <= 0 {
		return 0, false
	}
	rest := token[first_dot + 1:]
	second_rel := strings.index_byte(rest, '.')
	if second_rel <= 0 {
		return 0, false
	}
	if strings.index_byte(rest[second_rel + 1:], '.') >= 0 {
		return 0, false
	}

	header_part := token[:first_dot]
	payload_part := rest[:second_rel]
	sig_part := rest[second_rel + 1:]
	signing_input := token[:first_dot + 1 + second_rel]

	header_bytes, header_decode_err := base64.decode(header_part, base64.DEC_URL_TABLE, nil, allocator)
	if header_decode_err != nil {
		return 0, false
	}
	header_value, err := json.parse_string(string(header_bytes), .JSON, true, allocator)
	if err != .None {
		return 0, false
	}
	header_obj, is_obj := header_value.(json.Object)
	if !is_obj {
		return 0, false
	}
	alg_value, has_alg := header_obj["alg"]
	alg, is_str := alg_value.(json.String)
	if !has_alg || !is_str || alg != "HS256" {
		return 0, false
	}

	sig, sig_decode_err := base64.decode(sig_part, base64.DEC_URL_TABLE, nil, allocator)
	if sig_decode_err != nil {
		return 0, false
	}
	if len(sig) != hash.DIGEST_SIZES[.SHA256] {
		return 0, false
	}
	if !hmac.verify(.SHA256, sig, transmute([]byte)signing_input, secret) {
		return 0, false
	}

	payload_bytes, payload_decode_err := base64.decode(payload_part, base64.DEC_URL_TABLE, nil, allocator)
	if payload_decode_err != nil {
		return 0, false
	}
	payload_value, payload_err := json.parse_string(string(payload_bytes), .JSON, true, allocator)
	if payload_err != .None {
		return 0, false
	}
	payload_obj, payload_is_obj := payload_value.(json.Object)
	if !payload_is_obj {
		return 0, false
	}

	sub_value, has_sub := payload_obj["sub"]
	sub, sub_is_str := sub_value.(json.String)
	if !has_sub || !sub_is_str {
		return 0, false
	}
	parsed_id, id_ok := parse_positive_id(sub)
	if !id_ok {
		return 0, false
	}

	exp_value, has_exp := payload_obj["exp"]
	if !has_exp {
		return 0, false
	}
	exp: i64
	#partial switch v in exp_value {
	case json.Integer:
		exp = i64(v)
	case json.Float:
		if v != f64(i64(v)) {
			return 0, false
		}
		exp = i64(v)
	case:
		return 0, false
	}
	if exp <= time.to_unix_seconds(time.now()) {
		return 0, false
	}

	return parsed_id, true
}

auth_from_job :: proc(job: ^Job, secret: []byte) -> Auth {
	if !job.auth_present {
		return Auth{present = false, valid = true}
	}
	if !strings.has_prefix(job.auth, "Token ") {
		return Auth{present = true, valid = false}
	}
	token := job.auth[len("Token "):]
	id, ok := verify_token(token, secret, context.temp_allocator)
	if !ok {
		return Auth{present = true, valid = false}
	}
	return Auth{viewer = id, token = token, present = true, valid = true}
}
