package main

parse_uint_decimal :: proc(s: string) -> (n: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
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
	return n, true
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200: return "OK"
	case 201: return "Created"
	case 204: return "No Content"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 413: return "Payload Too Large"
	case 422: return "Unprocessable Entity"
	case 500: return "Internal Server Error"
	case: return "OK"
	}
}
