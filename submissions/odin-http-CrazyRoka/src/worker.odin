package main

import "base:runtime"

import "core:fmt"
import "core:mem/virtual"
import "core:strings"

import "lib:http"
import "lib:pq"

MAX_READ_PARAMS :: 4

Param_Kind :: enum {
	Text,
	Int,
}

Read_Param :: struct {
	kind: Param_Kind,
	int:  i64,
	text: string,
}

param_int :: proc(v: i64) -> Read_Param {
	return {kind = .Int, int = v}
}

param_text :: proc(s: string) -> Read_Param {
	return {kind = .Text, text = s}
}

Read_Kind :: enum {
	Article,
	Profile,
	Comments,
	List,
	CurrentUser,
	Tags,
}

Read_Slot :: struct {
	job:      ^Job,
	kind:     Read_Kind,
	auth:     Auth,
	close:    bool,
	stmt:     Stmt,
	n_params: int,
	params:   [MAX_READ_PARAMS]Read_Param,
	mode:     List_Mode,
	filter:   string,
	limit:    i64,
	offset:   i64,
	sent:     bool,
}

Preflight :: enum {
	// Query is queued for the pipelined read phase.
	Pipeline,
	// Not a single-statement read: run the normal synchronous handler.
	Sync,
	// A validation error was already sent; nothing else to do.
	Done,
}

worker_loop :: proc(w: ^Worker) {
	jobs: [BATCH_MAX]^Job
	for {
		n := queue_pop_batch(&g_app.queue, jobs[:])
		if n == 0 {
			return
		}
		handle_batch(w, jobs[:n])
	}
}

// Reproduces handle_job's ordering (body, auth, validation) and, for single
// statement reads, builds the statement and parameters without executing.
preflight_read :: proc(w: ^Worker, job: ^Job) -> (slot: Read_Slot, action: Preflight) {
	slot.job = job
	slot.close = job.body_err != nil || http.connection_should_close(job.conn)
	if job.body_err != nil {
		return slot, .Sync
	}

	auth := auth_from_job(job, g_app.jwt_secret)
	slot.auth = auth

	if job.ep == .Tags {
		slot.kind = .Tags
		slot.stmt = .Tags
		return slot, .Pipeline
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
		send_error(job.conn, 401, "unauthorized", slot.close)
		return slot, .Done
	}
	if optional && auth.present && !auth.valid {
		send_error(job.conn, 401, "unauthorized", slot.close)
		return slot, .Done
	}

	#partial switch job.ep {
	case .GetArticle:
		if len(job.params) < 1 {
			send_error(job.conn, 404, "article not found", slot.close)
			return slot, .Done
		}
		slot.kind = .Article
		slot.stmt = .ArticleBySlug
		slot.n_params = 2
		slot.params[0] = param_int(auth.viewer)
		slot.params[1] = param_text(job.params[0])
	case .GetProfile:
		if len(job.params) < 1 {
			send_error(job.conn, 404, "profile not found", slot.close)
			return slot, .Done
		}
		slot.kind = .Profile
		slot.stmt = .ProfileByUsername
		slot.n_params = 2
		slot.params[0] = param_int(auth.viewer)
		slot.params[1] = param_text(job.params[0])
	case .ListComments:
		if len(job.params) < 1 {
			send_error(job.conn, 404, "article not found", slot.close)
			return slot, .Done
		}
		slot.kind = .Comments
		slot.stmt = .ListComments
		slot.n_params = 2
		slot.params[0] = param_int(auth.viewer)
		slot.params[1] = param_text(job.params[0])
	case .ListArticles:
		limit, offset, ok := limit_offset(job.req)
		if !ok {
			send_error(job.conn, 422, "limit must be 1-100 and offset >= 0", slot.close)
			return slot, .Done
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
		slot.kind = .List
		slot.mode = mode
		slot.filter = filter
		slot.limit = limit
		slot.offset = offset
		slot.params[0] = param_int(auth.viewer)
		slot.params[1] = param_int(limit)
		slot.params[2] = param_int(offset)
		switch mode {
		case .All:
			slot.stmt = .ListAll
			slot.n_params = 3
		case .Tag:
			slot.stmt = .ListByTag
			slot.params[3] = param_text(filter)
			slot.n_params = 4
		case .Author:
			slot.stmt = .ListByAuthor
			slot.params[3] = param_text(filter)
			slot.n_params = 4
		case .Favorited:
			slot.stmt = .ListByFavorited
			slot.params[3] = param_text(filter)
			slot.n_params = 4
		case .Feed:
			return slot, .Sync
		}
	case .Feed:
		limit, offset, ok := limit_offset(job.req)
		if !ok {
			send_error(job.conn, 422, "limit must be 1-100 and offset >= 0", slot.close)
			return slot, .Done
		}
		slot.kind = .List
		slot.mode = .Feed
		slot.limit = limit
		slot.offset = offset
		slot.stmt = .ListFeed
		slot.n_params = 3
		slot.params[0] = param_int(auth.viewer)
		slot.params[1] = param_int(limit)
		slot.params[2] = param_int(offset)
	case .CurrentUser:
		slot.kind = .CurrentUser
		slot.stmt = .UserById
		slot.n_params = 1
		slot.params[0] = param_int(auth.viewer)
	case:
		return slot, .Sync
	}
	return slot, .Pipeline
}

send_read :: proc(w: ^Worker, slot: ^Read_Slot) -> bool {
	params := slot.params[:slot.n_params]
	values := make([][^]byte, len(params), context.temp_allocator)
	lengths := make([]i32, len(params), context.temp_allocator)
	formats := make([]pq.Format, len(params), context.temp_allocator)
	int_bufs: [MAX_READ_PARAMS][8]byte

	for p, i in params {
		switch p.kind {
		case .Int:
			v := u64(p.int)
			for k in 0..<8 {
				int_bufs[i][7 - k] = byte(v & 0xFF)
				v >>= 8
			}
			values[i] = ([^]byte)(&int_bufs[i][0])
			lengths[i] = 8
			formats[i] = .Binary
		case .Text:
			values[i] = ([^]byte)(strings.clone_to_cstring(p.text, context.temp_allocator))
			lengths[i] = i32(len(p.text))
			formats[i] = .Text
		}
	}

	values_ptr: [^][^]byte
	lengths_ptr: [^]i32
	formats_ptr: [^]pq.Format
	if len(values) > 0 {
		values_ptr = &values[0]
		lengths_ptr = &lengths[0]
		formats_ptr = &formats[0]
	}

	return pq.send_query_prepared(w.conn, stmt_name(slot.stmt), i32(len(values)), values_ptr, lengths_ptr, formats_ptr, .Text) != false
}

render_read :: proc(w: ^Worker, slot: Read_Slot, res: pq.Result) {
	if res == nil || !db_ok(res) {
		send_error(slot.job.conn, 500, "internal error", slot.close)
		return
	}

	switch slot.kind {
	case .Article:
		if pq.n_tuples(res) == 0 {
			send_error(slot.job.conn, 404, "article not found", slot.close)
			return
		}
		send_article_response(slot.job.conn, 200, read_article(res, 0, true), slot.close)
	case .Profile:
		if pq.n_tuples(res) == 0 {
			send_error(slot.job.conn, 404, "profile not found", slot.close)
			return
		}
		send_profile_response(slot.job.conn, read_profile(res, 0), slot.close)
	case .Comments:
		n := pq.n_tuples(res)
		if n == 0 {
			send_error(slot.job.conn, 404, "article not found", slot.close)
			return
		}
		if pq.get_is_null(res, 0, 0) {
			send_comments_response(slot.job.conn, nil, slot.close)
			return
		}
		out := make([dynamic]Comment_Row, 0, n, context.temp_allocator)
		for i in 0..<n {
			append(&out, read_comment(res, i))
		}
		send_comments_response(slot.job.conn, out[:], slot.close)
	case .List:
		n := pq.n_tuples(res)
		out := make([dynamic]Article_Row, 0, n, context.temp_allocator)
		for i in 0..<n {
			append(&out, read_article(res, i, false))
		}
		count := i64(0)
		if len(out) > 0 {
			count = out[0].total_count
		} else {
			c, ok := db_count_articles(w.conn, slot.auth.viewer, slot.mode, slot.filter)
			if !ok {
				send_error(slot.job.conn, 500, "internal error", slot.close)
				return
			}
			count = c
		}
		send_articles_response(slot.job.conn, out[:], count, slot.close)
	case .CurrentUser:
		if pq.n_tuples(res) == 0 {
			send_error(slot.job.conn, 401, "unauthorized", slot.close)
			return
		}
		send_user_response(slot.job.conn, 200, read_user(res, 0), slot.auth.token, slot.close)
	case .Tags:
		tags_json := "[]"
		if pq.n_tuples(res) > 0 {
			tags_json = read_text(res, 0, 0).? or_else "[]"
		}
		j := json_init(256 + len(tags_json))
		first := true
		json_obj_begin(&j)
		json_key(&j, &first, "tags")
		json_raw(&j, tags_json)
		json_obj_end(&j)
		send_json(slot.job.conn, 200, &j, slot.close)
	}
}

handle_batch :: proc(w: ^Worker, jobs: []^Job) {
	temp := virtual.arena_allocator(&w.temp)
	context.temp_allocator = temp

	slots := make([dynamic]Read_Slot, 0, len(jobs), temp)

	for job in jobs {
		slot, action := preflight_read(w, job)
		switch action {
		case .Done:
		// response already sent
		case .Sync:
			handle_job(w, job)
		case .Pipeline:
			append(&slots, slot)
		}
	}

	if len(slots) > 0 {
		if !pq.enter_pipeline_mode(w.conn) {
			for i in 0..<len(slots) {
				handle_job(w, slots[i].job)
			}
		} else {
			any_sent := false
			for i in 0..<len(slots) {
				slots[i].sent = send_read(w, &slots[i])
				any_sent = any_sent || slots[i].sent
			}
			if any_sent {
				pq.pipeline_sync(w.conn)
			}

			results := make([]pq.Result, len(slots), temp)
			for i in 0..<len(slots) {
				if !slots[i].sent {
					continue
				}
				// In pipeline mode PQgetResult yields a query's result(s), then a
				// NULL delimiter before the next query's results.
				first: pq.Result = nil
				for {
					r := pq.get_result(w.conn)
					if r == nil {
						break
					}
					if first == nil {
						first = r
					} else {
						pq.clear(r)
					}
				}
				results[i] = first
			}
			if any_sent {
				sync_res := pq.get_result(w.conn)
				if sync_res != nil {
					pq.clear(sync_res)
				}
				// Consume the trailing NULL that ends the pipeline.
				tail := pq.get_result(w.conn)
				if tail != nil {
					pq.clear(tail)
				}
			}

			if !pq.exit_pipeline_mode(w.conn) {
				for {
					r := pq.get_result(w.conn)
					if r == nil {
						break
					}
					pq.clear(r)
				}
				_ = pq.exit_pipeline_mode(w.conn)
			}

			for i in 0..<len(slots) {
				if slots[i].sent {
					render_read(w, slots[i], results[i])
					if results[i] != nil {
						pq.clear(results[i])
					}
				} else {
					send_error(slots[i].job.conn, 500, "internal error", slots[i].close)
				}
			}
		}
	}

	for job in jobs {
		free(job, runtime.heap_allocator())
	}
	free_all(temp)
}
