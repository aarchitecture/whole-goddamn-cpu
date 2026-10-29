package main

import "base:runtime"

import "core:mem/virtual"
import "core:sync"

import "lib:http"
import "lib:pq"

MAX_BODY :: 1 << 20
DEFAULT_DB_WORKERS :: 8
DEFAULT_IO_THREADS :: 2
BATCH_MAX :: 16

Endpoint :: enum {
	Register,
	Login,
	CurrentUser,
	UpdateUser,

	GetProfile,
	Follow,
	Unfollow,

	ListArticles,
	Feed,
	GetArticle,
	CreateArticle,
	UpdateArticle,
	DeleteArticle,

	Favorite,
	Unfavorite,

	ListComments,
	CreateComment,
	DeleteComment,

	Tags,
}

Job :: struct {
	conn:         ^http.Connection,
	req:          ^http.Request,
	ep:           Endpoint,
	body:         http.Body,
	body_err:     http.Body_Error,
	params:       []string,
	is_head:      bool,
	auth:         string,
	auth_present: bool,
}

Body_Ctx :: struct {
	conn: ^http.Connection,
	req:  ^http.Request,
	ep:   Endpoint,
}

Worker :: struct {
	app:        ^App,
	conn:       pq.Conn,
	temp:       virtual.Arena,
	crypt_data: []byte,
	index:      int,
}

App :: struct {
	db_conninfo: cstring,
	jwt_secret:  []byte,
	workers:     []Worker,
	queue:       Job_Queue,
}

Job_Queue :: struct {
	mu:     sync.Mutex,
	cond:   sync.Cond,
	jobs:   [dynamic]^Job,
	head:   int,
	closed: bool,
}

g_app: ^App

queue_push :: proc(q: ^Job_Queue, job: ^Job) {
	sync.lock(&q.mu)
	append(&q.jobs, job)
	sync.cond_signal(&q.cond)
	sync.unlock(&q.mu)
}

queue_pop :: proc(q: ^Job_Queue) -> ^Job {
	sync.lock(&q.mu)
	for q.head >= len(q.jobs) && !q.closed {
		sync.cond_wait(&q.cond, &q.mu)
	}

	if q.head >= len(q.jobs) {
		sync.unlock(&q.mu)
		return nil
	}

	job := q.jobs[q.head]
	q.head += 1

	if q.head > 1024 && q.head * 2 >= len(q.jobs) {
		remaining := len(q.jobs) - q.head
		copy(q.jobs[:remaining], q.jobs[q.head:])
		resize(&q.jobs, remaining)
		q.head = 0
	}

	sync.unlock(&q.mu)
	return job
}

queue_pop_batch :: proc(q: ^Job_Queue, out: []^Job) -> int {
	sync.lock(&q.mu)
	for q.head >= len(q.jobs) && !q.closed {
		sync.cond_wait(&q.cond, &q.mu)
	}

	if q.head >= len(q.jobs) {
		sync.unlock(&q.mu)
		return 0
	}

	n := 0
	for n < len(out) && q.head < len(q.jobs) {
		out[n] = q.jobs[q.head]
		q.head += 1
		n += 1
	}

	if q.head > 1024 && q.head * 2 >= len(q.jobs) {
		remaining := len(q.jobs) - q.head
		copy(q.jobs[:remaining], q.jobs[q.head:])
		resize(&q.jobs, remaining)
		q.head = 0
	}

	sync.unlock(&q.mu)
	return n
}

enqueue_job :: proc(ctx: ^Body_Ctx, body: http.Body, err: http.Body_Error) {
	job := new(Job, runtime.heap_allocator())
	job.conn = ctx.conn
	job.req = ctx.req
	job.ep = ctx.ep
	job.body = body
	job.body_err = err
	job.params = ctx.req.url_params
	job.is_head = ctx.req.is_head

	if auth, ok := http.headers_get_unsafe(ctx.req.headers, "authorization"); ok {
		job.auth = auth
		job.auth_present = true
	}

	queue_push(&g_app.queue, job)
}

on_request_body :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	enqueue_job((^Body_Ctx)(user_data), body, err)
}

handle_endpoint :: proc(ep: Endpoint, req: ^http.Request, res: ^http.Response) {
	ctx := new(Body_Ctx, context.temp_allocator)
	ctx.conn = http.connection_of_response(res)
	ctx.req = req
	ctx.ep = ep
	http.body(req, MAX_BODY, ctx, on_request_body)
}

endpoint_handler :: proc(ep: Endpoint) -> http.Handler {
	h: http.Handler
	h.user_data = rawptr(uintptr(ep))
	h.handle = proc(handler: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		handle_endpoint(Endpoint(uintptr(handler.user_data)), req, res)
	}
	return h
}
