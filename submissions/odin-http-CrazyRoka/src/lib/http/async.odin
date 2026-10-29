package http

import "base:runtime"

import "core:log"
import "core:nbio"

// Returns the connection associated with a response.
connection_of_response :: #force_inline proc(res: ^Response) -> ^Connection {
	return res._conn
}

// Returns whether this request/connection must be closed after the response.
// This is the same policy as response_must_close, but it never mutates the
// response headers, so it is safe to call from a worker thread.
connection_should_close :: proc(c: ^Connection) -> bool {
	req := &c.loop.req

	if v, ok := headers_get_unsafe(req.headers, "connection"); ok && v == "close" {
		return true
	}

	if body_ok, got := req._body_ok.?; got && !body_ok {
		return true
	}

	if c.state >= .Will_Close {
		return true
	}

	if line, ok := req.line.?; ok && line.version == {1, 0} {
		return true
	}

	return false
}

// Sends a complete HTTP response buffer from any thread. The buffer must be
// allocated with the heap allocator; ownership is transferred and it is freed
// when the send operation completes.
send_raw :: proc(c: ^Connection, buf: []byte, close: bool) {
	assert(!c.loop.res.sent, "response already sent")
	c.loop.res.sent = true

	nbio.send_poly3(
		c.socket,
		{buf},
		c,
		buf,
		close,
		on_async_sent,
		l = c.event_loop,
	)
}

@(private)
on_async_sent :: proc(op: ^nbio.Operation, c: ^Connection, buf: []byte, close: bool) {
	delete(buf, runtime.heap_allocator())
	finish_async_send(op, c, close)
}

// Sends the response head and body as separate iovecs. Both buffers must be
// allocated with the heap allocator; ownership is transferred and they are
// freed when the send operation completes.
send_raw_parts :: proc(c: ^Connection, head, body: []byte, close: bool) {
	assert(!c.loop.res.sent, "response already sent")
	c.loop.res.sent = true
	c.loop.send_head = head
	c.loop.send_body = body

	nbio.send_poly2(
		c.socket,
		{head, body},
		c,
		close,
		on_async_sent_parts,
		l = c.event_loop,
	)
}

@(private)
on_async_sent_parts :: proc(op: ^nbio.Operation, c: ^Connection, close: bool) {
	delete(c.loop.send_head, runtime.heap_allocator())
	delete(c.loop.send_body, runtime.heap_allocator())
	c.loop.send_head = nil
	c.loop.send_body = nil
	finish_async_send(op, c, close)
}

@(private)
finish_async_send :: proc(op: ^nbio.Operation, c: ^Connection, close: bool) {
	will_close := close
	if op.send.err != nil {
		log.errorf("async response send failed: %v", op.send.err)
		will_close = true
	}

	clean_request_loop(c, will_close)
}
