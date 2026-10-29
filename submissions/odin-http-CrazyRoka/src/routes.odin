package main

import "lib:http"

not_found_handler :: proc(handler: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	res.status = .Not_Found
	http.headers_set_content_type(&res.headers, "application/json")
	http.body_set(res, `{"errors":{"body":["not found"]}}`)
	http.respond(res)
}

build_router :: proc() -> http.Router {
	router: http.Router
	http.router_init(&router)

	http.route_post(&router, "/api/users", endpoint_handler(.Register))
	http.route_post(&router, "/api/users/login", endpoint_handler(.Login))
	http.route_get(&router, "/api/user", endpoint_handler(.CurrentUser))
	http.route_put(&router, "/api/user", endpoint_handler(.UpdateUser))

	http.route_get(&router, "/api/profiles/([^/]+)", endpoint_handler(.GetProfile))
	http.route_post(&router, "/api/profiles/([^/]+)/follow", endpoint_handler(.Follow))
	http.route_delete(&router, "/api/profiles/([^/]+)/follow", endpoint_handler(.Unfollow))

	http.route_get(&router, "/api/articles", endpoint_handler(.ListArticles))
	http.route_post(&router, "/api/articles", endpoint_handler(.CreateArticle))
	http.route_get(&router, "/api/articles/feed", endpoint_handler(.Feed))
	http.route_get(&router, "/api/articles/([^/]+)", endpoint_handler(.GetArticle))
	http.route_put(&router, "/api/articles/([^/]+)", endpoint_handler(.UpdateArticle))
	http.route_delete(&router, "/api/articles/([^/]+)", endpoint_handler(.DeleteArticle))

	http.route_post(&router, "/api/articles/([^/]+)/favorite", endpoint_handler(.Favorite))
	http.route_delete(&router, "/api/articles/([^/]+)/favorite", endpoint_handler(.Unfavorite))

	http.route_get(&router, "/api/articles/([^/]+)/comments", endpoint_handler(.ListComments))
	http.route_post(&router, "/api/articles/([^/]+)/comments", endpoint_handler(.CreateComment))
	http.route_delete(&router, "/api/articles/([^/]+)/comments/(%d+)", endpoint_handler(.DeleteComment))

	http.route_get(&router, "/api/tags", endpoint_handler(.Tags))

	not_found: http.Handler
	not_found.handle = not_found_handler
	http.route_all(&router, ".*", not_found)
	return router
}
