package main

import "core:encoding/json"
import "core:strings"

import "lib:http"

parse_wrapper :: proc(body: string, key: string) -> (m: json.Object, ok: bool) {
	if len(body) == 0 {
		return nil, false
	}
	value, err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if err != .None {
		return nil, false
	}
	top, is_obj := value.(json.Object)
	if !is_obj {
		return nil, false
	}
	inner_value, has_key := top[key]
	if !has_key {
		return nil, false
	}
	inner, is_inner_obj := inner_value.(json.Object)
	if !is_inner_obj {
		return nil, false
	}
	return inner, true
}

req_string :: proc(m: json.Object, key: string) -> (s: string, ok: bool) {
	value, has_key := m[key]
	if !has_key {
		return "", false
	}
	str, is_str := value.(json.String)
	if !is_str || str == "" {
		return "", false
	}
	return string(str), true
}

opt_nonempty_string :: proc(m: json.Object, key: string) -> (s: Maybe(string), ok: bool) {
	value, has_key := m[key]
	if !has_key {
		return nil, true
	}
	if _, is_null := value.(json.Null); is_null {
		return nil, true
	}
	str, is_str := value.(json.String)
	if !is_str || str == "" {
		return nil, false
	}
	return string(str), true
}

opt_string :: proc(m: json.Object, key: string) -> (s: Maybe(string), ok: bool) {
	value, has_key := m[key]
	if !has_key {
		return nil, true
	}
	if _, is_null := value.(json.Null); is_null {
		return nil, true
	}
	str, is_str := value.(json.String)
	if !is_str {
		return nil, false
	}
	return string(str), true
}

parse_tag_list :: proc(m: json.Object) -> (tags: []string, ok: bool) {
	value, has_key := m["tagList"]
	if !has_key {
		return nil, true
	}
	if _, is_null := value.(json.Null); is_null {
		return nil, true
	}
	arr, is_arr := value.(json.Array)
	if !is_arr {
		return nil, false
	}
	out := make([dynamic]string, 0, len(arr), context.temp_allocator)
	for item in arr {
		str, is_str := item.(json.String)
		if !is_str || str == "" {
			return nil, false
		}
		append(&out, string(str))
	}
	return out[:], true
}

build_tags_json :: proc(tags: []string) -> string {
	j := json_init(64)
	json_arr_begin(&j)
	first := true
	for tag in tags {
		json_comma(&j, &first)
		json_str(&j, tag)
	}
	json_arr_end(&j)
	out := strings.clone(string(j.b[:]), context.temp_allocator)
	json_destroy(&j)
	return out
}

limit_offset :: proc(req: ^http.Request) -> (limit, offset: i64, ok: bool) {
	limit = 20
	offset = 0

	if s, present := http.query_get(req.url, "limit"); present {
		n, valid := parse_uint_decimal(s)
		if !valid || n < 1 || n > 100 {
			return 0, 0, false
		}
		limit = n
	}
	if s, present := http.query_get(req.url, "offset"); present {
		n, valid := parse_uint_decimal(s)
		if !valid {
			return 0, 0, false
		}
		offset = n
	}
	return limit, offset, true
}

send_user_response :: proc(conn: ^http.Connection, status: int, u: User_Row, token: string, close: bool) {
	j := json_init(256)
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "user")
	render_user(&j, u, token)
	json_obj_end(&j)
	send_json(conn, status, &j, close)
}

send_profile_response :: proc(conn: ^http.Connection, p: Profile_Row, close: bool) {
	j := json_init(192)
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "profile")
	render_profile(&j, p)
	json_obj_end(&j)
	send_json(conn, 200, &j, close)
}

send_article_response :: proc(conn: ^http.Connection, status: int, a: Article_Row, close: bool) {
	j := json_init(1024 + len(a.body))
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "article")
	render_article(&j, a, true)
	json_obj_end(&j)
	send_json(conn, status, &j, close)
}

send_articles_response :: proc(conn: ^http.Connection, rows: []Article_Row, count: i64, close: bool) {
	j := json_init(1024 + len(rows) * 512)
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "articles")
	json_arr_begin(&j)
	arr_first := true
	for a in rows {
		json_comma(&j, &arr_first)
		render_article(&j, a, false)
	}
	json_arr_end(&j)
	json_key(&j, &first, "articlesCount")
	json_i64(&j, count)
	json_obj_end(&j)
	send_json(conn, 200, &j, close)
}

send_comment_response :: proc(conn: ^http.Connection, status: int, c: Comment_Row, close: bool) {
	j := json_init(512)
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "comment")
	render_comment(&j, c)
	json_obj_end(&j)
	send_json(conn, status, &j, close)
}

send_comments_response :: proc(conn: ^http.Connection, rows: []Comment_Row, close: bool) {
	j := json_init(512 + len(rows) * 256)
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "comments")
	json_arr_begin(&j)
	arr_first := true
	for c in rows {
		json_comma(&j, &arr_first)
		render_comment(&j, c)
	}
	json_arr_end(&j)
	json_obj_end(&j)
	send_json(conn, 200, &j, close)
}

handle_job :: proc(w: ^Worker, job: ^Job) {
	close := job.body_err != nil || http.connection_should_close(job.conn)
	if job.body_err != nil {
		send_error(job.conn, 413, "request body too large", true)
		return
	}

	auth := auth_from_job(job, g_app.jwt_secret)

	#partial switch job.ep {
	case .Register:
		handle_register(w, job, close)
		return
	case .Login:
		handle_login(w, job, close)
		return
	case .Tags:
		handle_tags(w, job, close)
		return
	}

	required := false
	optional := false
	#partial switch job.ep {
	case .CurrentUser, .UpdateUser, .Follow, .Unfollow, .Feed, .CreateArticle,
	     .UpdateArticle, .DeleteArticle, .Favorite, .Unfavorite, .CreateComment, .DeleteComment:
		required = true
	case .GetProfile, .ListArticles, .GetArticle, .ListComments:
		optional = true
	}

	if required && (!auth.present || !auth.valid) {
		send_error(job.conn, 401, "unauthorized", close)
		return
	}
	if optional && auth.present && !auth.valid {
		send_error(job.conn, 401, "unauthorized", close)
		return
	}

	switch job.ep {
	case .CurrentUser:
		handle_current_user(w, job, auth, close)
	case .UpdateUser:
		handle_update_user(w, job, auth, close)
	case .GetProfile:
		handle_get_profile(w, job, auth, close)
	case .Follow:
		handle_follow(w, job, auth, true, close)
	case .Unfollow:
		handle_follow(w, job, auth, false, close)
	case .ListArticles:
		handle_list_articles(w, job, auth, close)
	case .Feed:
		handle_feed(w, job, auth, close)
	case .GetArticle:
		handle_get_article(w, job, auth, close)
	case .CreateArticle:
		handle_create_article(w, job, auth, close)
	case .UpdateArticle:
		handle_update_article(w, job, auth, close)
	case .DeleteArticle:
		handle_delete_article(w, job, auth, close)
	case .Favorite:
		handle_favorite(w, job, auth, true, close)
	case .Unfavorite:
		handle_favorite(w, job, auth, false, close)
	case .ListComments:
		handle_list_comments(w, job, auth, close)
	case .CreateComment:
		handle_create_comment(w, job, auth, close)
	case .DeleteComment:
		handle_delete_comment(w, job, auth, close)
	case .Register, .Login, .Tags:
		unreachable()
	}
}

handle_register :: proc(w: ^Worker, job: ^Job, close: bool) {
	m, ok := parse_wrapper(job.body, "user")
	if !ok {
		send_error(job.conn, 422, "invalid body", close)
		return
	}
	username, ok1 := req_string(m, "username")
	email, ok2 := req_string(m, "email")
	password, ok3 := req_string(m, "password")
	if !ok1 || !ok2 || !ok3 {
		send_error(job.conn, 422, "username, email and password are required", close)
		return
	}
	hash, hash_ok := hash_password(password, w.crypt_data)
	if !hash_ok {
		send_error(job.conn, 422, "password is too long", close)
		return
	}
	u, unique, db_ok := db_register_user(w.conn, username, email, hash)
	if unique {
		send_error(job.conn, 422, "username or email is already taken", close)
		return
	}
	if !db_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	token := issue_token(u.id, g_app.jwt_secret)
	send_user_response(job.conn, 201, u, token, close)
}

handle_login :: proc(w: ^Worker, job: ^Job, close: bool) {
	m, ok := parse_wrapper(job.body, "user")
	if !ok {
		send_error(job.conn, 422, "invalid body", close)
		return
	}
	email, ok1 := req_string(m, "email")
	password, ok2 := req_string(m, "password")
	if !ok1 || !ok2 {
		send_error(job.conn, 422, "email and password are required", close)
		return
	}
	u, found, db_ok := db_get_user_by_email(w.conn, email)
	if !db_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 401, "invalid email or password", close)
		return
	}
	hash := u.password_hash.? or_else ""
	if !verify_password(password, hash, w.crypt_data) {
		send_error(job.conn, 401, "invalid email or password", close)
		return
	}
	token := issue_token(u.id, g_app.jwt_secret)
	send_user_response(job.conn, 200, u, token, close)
}

handle_current_user :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	u, found, ok := db_get_user_by_id(w.conn, auth.viewer)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 401, "unauthorized", close)
		return
	}
	send_user_response(job.conn, 200, u, auth.token, close)
}

handle_update_user :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	m, ok := parse_wrapper(job.body, "user")
	if !ok {
		send_error(job.conn, 422, "invalid body", close)
		return
	}
	email, ok1 := opt_nonempty_string(m, "email")
	username, ok2 := opt_nonempty_string(m, "username")
	password, ok3 := opt_nonempty_string(m, "password")
	bio, ok4 := opt_string(m, "bio")
	image, ok5 := opt_string(m, "image")
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 {
		send_error(job.conn, 422, "invalid user fields", close)
		return
	}

	hash: Maybe(string)
	if pw, has_pw := password.?; has_pw {
		h, hash_ok := hash_password(pw, w.crypt_data)
		if !hash_ok {
			send_error(job.conn, 422, "password is too long", close)
			return
		}
		hash = h
	}

	u, unique, found, db_ok := db_update_user(w.conn, auth.viewer, email, username, hash, bio, image)
	if unique {
		send_error(job.conn, 422, "username or email is already taken", close)
		return
	}
	if !db_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 401, "unauthorized", close)
		return
	}
	send_user_response(job.conn, 200, u, auth.token, close)
}

handle_get_profile :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	if len(job.params) < 1 {
		send_error(job.conn, 404, "profile not found", close)
		return
	}
	p, found, ok := db_get_profile(w.conn, job.params[0], auth.viewer)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "profile not found", close)
		return
	}
	send_profile_response(job.conn, p, close)
}

handle_follow :: proc(w: ^Worker, job: ^Job, auth: Auth, follow: bool, close: bool) {
	if len(job.params) < 1 {
		send_error(job.conn, 404, "profile not found", close)
		return
	}
	p, found, ok := db_set_follow(w.conn, job.params[0], auth.viewer, follow)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "profile not found", close)
		return
	}
	send_profile_response(job.conn, p, close)
}

handle_list_articles :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	limit, offset, ok := limit_offset(job.req)
	if !ok {
		send_error(job.conn, 422, "limit must be 1-100 and offset >= 0", close)
		return
	}

	mode := List_Mode.All
	filter := ""
	if tag, has_tag := http.query_get_percent_decoded(job.req.url, "tag", context.temp_allocator); has_tag && tag != "" {
		mode = .Tag
		filter = tag
	} else if author, has_author := http.query_get_percent_decoded(job.req.url, "author", context.temp_allocator); has_author && author != "" {
		mode = .Author
		filter = author
	} else if favorited, has_fav := http.query_get_percent_decoded(job.req.url, "favorited", context.temp_allocator); has_fav && favorited != "" {
		mode = .Favorited
		filter = favorited
	}

	rows, list_ok := db_list_articles(w.conn, auth.viewer, mode, filter, limit, offset)
	if !list_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	count := i64(0)
	if len(rows) > 0 {
		count = rows[0].total_count
	} else {
		count_ok: bool
		count, count_ok = db_count_articles(w.conn, auth.viewer, mode, filter)
		if !count_ok {
			send_error(job.conn, 500, "internal error", close)
			return
		}
	}
	send_articles_response(job.conn, rows, count, close)
}

handle_feed :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	limit, offset, ok := limit_offset(job.req)
	if !ok {
		send_error(job.conn, 422, "limit must be 1-100 and offset >= 0", close)
		return
	}
	rows, list_ok := db_list_articles(w.conn, auth.viewer, .Feed, "", limit, offset)
	if !list_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	count := i64(0)
	if len(rows) > 0 {
		count = rows[0].total_count
	} else {
		count_ok: bool
		count, count_ok = db_count_articles(w.conn, auth.viewer, .Feed, "")
		if !count_ok {
			send_error(job.conn, 500, "internal error", close)
			return
		}
	}
	send_articles_response(job.conn, rows, count, close)
}

handle_get_article :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	if len(job.params) < 1 {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	a, found, ok := db_get_article_by_slug(w.conn, job.params[0], auth.viewer)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	send_article_response(job.conn, 200, a, close)
}

handle_create_article :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	m, ok := parse_wrapper(job.body, "article")
	if !ok {
		send_error(job.conn, 422, "invalid body", close)
		return
	}
	title, ok1 := req_string(m, "title")
	description, ok2 := req_string(m, "description")
	body, ok3 := req_string(m, "body")
	if !ok1 || !ok2 || !ok3 {
		send_error(job.conn, 422, "title, description and body are required", close)
		return
	}
	tags, tags_ok := parse_tag_list(m)
	if !tags_ok {
		send_error(job.conn, 422, "tagList must be an array of non-empty strings", close)
		return
	}
	tags_json := build_tags_json(tags)

	_, slug, create_ok := db_create_article(w.conn, auth.viewer, title, description, body, tags_json)
	if !create_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	a, article_found, get_ok := db_get_article_by_slug(w.conn, slug, auth.viewer)
	if !get_ok || !article_found {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	send_article_response(job.conn, 201, a, close)
}

handle_update_article :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	m, ok := parse_wrapper(job.body, "article")
	if !ok {
		send_error(job.conn, 422, "invalid body", close)
		return
	}
	title, ok1 := opt_nonempty_string(m, "title")
	description, ok2 := opt_nonempty_string(m, "description")
	body, ok3 := opt_nonempty_string(m, "body")
	if !ok1 || !ok2 || !ok3 {
		send_error(job.conn, 422, "title, description and body must be non-empty strings", close)
		return
	}
	if len(job.params) < 1 {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	id, author_id, found, owner_ok := db_article_owner(w.conn, job.params[0])
	if !owner_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	if author_id != auth.viewer {
		send_error(job.conn, 403, "not the author", close)
		return
	}
	slug, update_found, update_ok := db_update_article(w.conn, id, title, description, body)
	if !update_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !update_found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	a, get_found, get_ok := db_get_article_by_slug(w.conn, slug, auth.viewer)
	if !get_ok || !get_found {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	send_article_response(job.conn, 200, a, close)
}

handle_delete_article :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	if len(job.params) < 1 {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	id, author_id, found, ok := db_article_owner(w.conn, job.params[0])
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	if author_id != auth.viewer {
		send_error(job.conn, 403, "not the author", close)
		return
	}
	if !db_delete_article(w.conn, id) {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	send_no_content(job.conn, close)
}

handle_favorite :: proc(w: ^Worker, job: ^Job, auth: Auth, favorite: bool, close: bool) {
	if len(job.params) < 1 {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	a, found, ok := db_set_favorite(w.conn, job.params[0], auth.viewer, favorite)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	send_article_response(job.conn, 200, a, close)
}

handle_list_comments :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	if len(job.params) < 1 {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	rows, found, list_ok := db_list_comments(w.conn, auth.viewer, job.params[0])
	if !list_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	send_comments_response(job.conn, rows, close)
}

handle_create_comment :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	m, ok := parse_wrapper(job.body, "comment")
	if !ok {
		send_error(job.conn, 422, "invalid body", close)
		return
	}
	body, body_ok := req_string(m, "body")
	if !body_ok {
		send_error(job.conn, 422, "body is required", close)
		return
	}
	if len(job.params) < 1 {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	c, found, comment_ok := db_create_comment(w.conn, job.params[0], auth.viewer, body)
	if !comment_ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "article not found", close)
		return
	}
	send_comment_response(job.conn, 201, c, close)
}

handle_delete_comment :: proc(w: ^Worker, job: ^Job, auth: Auth, close: bool) {
	if len(job.params) < 2 {
		send_error(job.conn, 404, "comment not found", close)
		return
	}
	comment_id, id_ok := parse_uint_decimal(job.params[1])
	if !id_ok {
		send_error(job.conn, 404, "comment not found", close)
		return
	}
	author_id, found, ok := db_delete_comment(w.conn, comment_id, job.params[0], auth.viewer)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	if !found {
		send_error(job.conn, 404, "comment not found", close)
		return
	}
	if author_id != auth.viewer {
		send_error(job.conn, 403, "not the author", close)
		return
	}
	send_no_content(job.conn, close)
}

handle_tags :: proc(w: ^Worker, job: ^Job, close: bool) {
	tags_json, ok := db_tags(w.conn)
	if !ok {
		send_error(job.conn, 500, "internal error", close)
		return
	}
	j := json_init(256 + len(tags_json))
	first := true
	json_obj_begin(&j)
	json_key(&j, &first, "tags")
	json_raw(&j, tags_json)
	json_obj_end(&j)
	send_json(job.conn, 200, &j, close)
}

