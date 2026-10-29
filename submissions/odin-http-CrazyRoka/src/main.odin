package main

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"

import "lib:http"
import "lib:pq"

main :: proc() {
	context.logger = log.create_console_logger(.Error)

	host := os.get_env("HOST", context.allocator)
	if host == "" {
		host = "0.0.0.0"
	}
	port := os.get_env("PORT", context.allocator)
	if port == "" {
		port = "8080"
	}
	db_url := os.get_env("DATABASE_URL", context.allocator)
	if db_url == "" {
		db_url = "postgres://conduit:conduit@127.0.0.1:5432/conduit"
	}
	jwt := os.get_env("JWT_SECRET", context.allocator)
	if jwt == "" {
		jwt = "multicore-server-challenge"
	}

	db_workers := DEFAULT_DB_WORKERS
	if s := os.get_env("DB_WORKERS", context.allocator); s != "" {
		if n, ok := parse_uint_decimal(s); ok && n > 0 && n < 100 {
			db_workers = int(n)
		}
	}
	io_threads := DEFAULT_IO_THREADS
	if s := os.get_env("IO_THREADS", context.allocator); s != "" {
		if n, ok := parse_uint_decimal(s); ok && n > 0 && n < 256 {
			io_threads = int(n)
		}
	}

	app := new(App)
	app.db_conninfo = strings.clone_to_cstring(db_url, context.allocator)
	app.jwt_secret = transmute([]byte)jwt
	app.workers = make([]Worker, db_workers, context.allocator)
	g_app = app

	for i in 0..<db_workers {
		w := &app.workers[i]
		w.app = app
		w.index = i
		w.conn = pq.connectdb(app.db_conninfo)
		w.crypt_data = make([]byte, CRYPT_DATA_SIZE, context.allocator)
		if pq.status(w.conn) != .Ok {
			log.errorf("database connection %d failed", i)
			os.exit(1)
		}
		if !prepare_statements(w.conn) {
			log.errorf("failed to prepare statements on connection %d", i)
			os.exit(1)
		}
		err := virtual.arena_init_growing(&w.temp, 64 * 1024)
		assert(err == nil)
		thread.run_with_poly_data(w, worker_loop, context)
	}

	router := build_router()
	handler := http.router_handler(&router)

	endpoint_str := fmt.tprintf("%s:%s", host, port)
	endpoint, endpoint_ok := net.parse_endpoint(endpoint_str)
	if !endpoint_ok {
		log.errorf("invalid listen endpoint %q", endpoint_str)
		os.exit(1)
	}

	opts := http.Default_Server_Opts
	opts.thread_count = io_threads
	opts.auto_expect_continue = false
	opts.redirect_head_to_get = true

	server: http.Server
	err := http.listen_and_serve(&server, handler, endpoint, opts)
	if err != nil {
		log.errorf("server failed: %v", err)
		os.exit(1)
	}
}
