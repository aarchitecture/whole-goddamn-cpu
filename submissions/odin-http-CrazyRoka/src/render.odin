package main

import "base:runtime"

import "core:strconv"

import "lib:http"

json_maybe_str :: proc(j: ^Json, v: Maybe(string)) {
	if s, ok := v.?; ok {
		json_str(j, s)
	} else {
		json_null(j)
	}
}

render_author :: proc(j: ^Json, username: string, bio, image: Maybe(string), following: bool) {
	first := true
	json_obj_begin(j)
	json_key(j, &first, "username")
	json_str(j, username)
	json_key(j, &first, "bio")
	json_maybe_str(j, bio)
	json_key(j, &first, "image")
	json_maybe_str(j, image)
	json_key(j, &first, "following")
	json_bool(j, following)
	json_obj_end(j)
}

render_profile :: proc(j: ^Json, p: Profile_Row) {
	render_author(j, p.username, p.bio, p.image, p.following)
}

render_user :: proc(j: ^Json, u: User_Row, token: string) {
	first := true
	json_obj_begin(j)
	json_key(j, &first, "email")
	json_str(j, u.email)
	json_key(j, &first, "token")
	json_str(j, token)
	json_key(j, &first, "username")
	json_str(j, u.username)
	json_key(j, &first, "bio")
	json_maybe_str(j, u.bio)
	json_key(j, &first, "image")
	json_maybe_str(j, u.image)
	json_obj_end(j)
}

render_article :: proc(j: ^Json, a: Article_Row, include_body: bool) {
	first := true
	json_obj_begin(j)
	json_key(j, &first, "slug")
	json_str(j, a.slug)
	json_key(j, &first, "title")
	json_str(j, a.title)
	json_key(j, &first, "description")
	json_str(j, a.description)
	if include_body {
		json_key(j, &first, "body")
		json_str(j, a.body)
	}
	json_key(j, &first, "tagList")
	json_raw(j, a.tag_list_json)
	json_key(j, &first, "createdAt")
	json_str(j, a.created_at)
	json_key(j, &first, "updatedAt")
	json_str(j, a.updated_at)
	json_key(j, &first, "favorited")
	json_bool(j, a.favorited)
	json_key(j, &first, "favoritesCount")
	json_i64(j, a.favorites_count)
	json_key(j, &first, "author")
	render_author(j, a.author_username, a.author_bio, a.author_image, a.following)
	json_obj_end(j)
}

render_comment :: proc(j: ^Json, c: Comment_Row) {
	first := true
	json_obj_begin(j)
	json_key(j, &first, "id")
	json_i64(j, c.id)
	json_key(j, &first, "createdAt")
	json_str(j, c.created_at)
	json_key(j, &first, "updatedAt")
	json_str(j, c.updated_at)
	json_key(j, &first, "body")
	json_str(j, c.body)
	json_key(j, &first, "author")
	render_author(j, c.author_username, c.author_bio, c.author_image, c.following)
	json_obj_end(j)
}

append_int :: proc(buf: ^[dynamic]byte, n: int) {
	tmp: [32]byte
	append(buf, ..transmute([]byte)strconv.write_int(tmp[:], i64(n), 10))
}

send_json :: proc(conn: ^http.Connection, status: int, j: ^Json, close: bool) {
	head := make([dynamic]byte, 0, 128, runtime.heap_allocator())

	append(&head, "HTTP/1.1 ")
	append_int(&head, status)
	append(&head, ' ')
	append(&head, status_text(status))
	append(&head, "\r\n")
	append(&head, "Content-Type: application/json\r\n")
	append(&head, "Content-Length: ")
	append_int(&head, len(j.b))
	append(&head, "\r\n")
	if close {
		append(&head, "Connection: close\r\n")
	}
	append(&head, "\r\n")

	http.send_raw_parts(conn, head[:], j.b[:], close)
}

send_no_content :: proc(conn: ^http.Connection, close: bool) {
	buf := make([dynamic]byte, 0, 64, runtime.heap_allocator())

	append(&buf, "HTTP/1.1 204 No Content\r\n")
	if close {
		append(&buf, "Connection: close\r\n")
	}
	append(&buf, "\r\n")

	http.send_raw(conn, buf[:], close)
}

send_error :: proc(conn: ^http.Connection, status: int, message: string, close: bool) {
	j := json_init(128)
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "errors")
	json_obj_begin(&j)
	err_first := true
	json_key(&j, &err_first, "body")
	json_arr_begin(&j)
	json_str(&j, message)
	json_arr_end(&j)
	json_obj_end(&j)
	json_obj_end(&j)
	send_json(conn, status, &j, close)
}
