package main

import "base:runtime"

import "core:fmt"
import "core:strings"

import "lib:pq"

List_Mode :: enum {
	All,
	Tag,
	Author,
	Favorited,
	Feed,
}

Stmt :: enum {
	ArticleBySlug,
	ArticleById,
	FavoriteArticle,
	FollowProfile,
	ListAll,
	ListByTag,
	ListByAuthor,
	ListByFavorited,
	ListFeed,
	CountAll,
	CountByTag,
	CountByAuthor,
	CountByFavorited,
	CountFeed,
	InsertArticle,
	InsertTags,
	InsertArticleTags,
	UpdateArticle,
	ArticleOwner,
	ArticleIdBySlug,
	ProfileByUsername,
	ProfileById,
	UserById,
	UserByEmail,
	RegisterUser,
	UpdateUser,
	ListComments,
	CreateComment,
	CommentAuthor,
	Tags,
	SetFollow,
	DeleteFollow,
	SetFavorite,
	DeleteFavorite,
	DeleteArticle,
}

STMT_ALL := [?]Stmt{
	.ArticleBySlug, .ArticleById, .FavoriteArticle, .FollowProfile,
	.ListAll, .ListByTag, .ListByAuthor, .ListByFavorited, .ListFeed,
	.CountAll, .CountByTag, .CountByAuthor, .CountByFavorited, .CountFeed,
	.InsertArticle, .InsertTags, .InsertArticleTags, .UpdateArticle,
	.ArticleOwner, .ArticleIdBySlug,
	.ProfileByUsername, .ProfileById,
	.UserById, .UserByEmail, .RegisterUser, .UpdateUser,
	.ListComments, .CreateComment, .CommentAuthor, .Tags,
	.SetFollow, .DeleteFollow, .SetFavorite, .DeleteFavorite,
	.DeleteArticle,
}

Article_Row :: struct {
	id:              i64,
	slug:            string,
	title:           string,
	description:     string,
	body:            string,
	created_at:      string,
	updated_at:      string,
	tag_list_json:   string,
	favorites_count: i64,
	favorited:       bool,
	following:       bool,
	author_id:       i64,
	author_username: string,
	author_bio:      Maybe(string),
	author_image:    Maybe(string),
	total_count:     i64,
}

Comment_Row :: struct {
	id:              i64,
	body:            string,
	created_at:      string,
	updated_at:      string,
	author_id:       i64,
	author_username: string,
	author_bio:      Maybe(string),
	author_image:    Maybe(string),
	following:       bool,
}

Profile_Row :: struct {
	id:        i64,
	username:  string,
	bio:       Maybe(string),
	image:     Maybe(string),
	following: bool,
}

User_Row :: struct {
	id:            i64,
	username:      string,
	email:         string,
	bio:           Maybe(string),
	image:         Maybe(string),
	created_at:    string,
	password_hash: Maybe(string),
}

ARTICLE_LIST_SELECT :: `SELECT a.id, a.slug, a.title, a.description,
       a.created_at AT TIME ZONE 'UTC' AS created_at,
       a.updated_at AT TIME ZONE 'UTC' AS updated_at,
       array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
              FROM article_tags at
              WHERE at.article_id = a.id ORDER BY name))::text AS tag_list,
       fv.favorites_count,
       fv.favorited,
       u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following`

ARTICLE_SELECT_COLUMNS :: `SELECT a.id, a.slug, a.title, a.description, a.body,
       a.created_at AT TIME ZONE 'UTC' AS created_at,
       a.updated_at AT TIME ZONE 'UTC' AS updated_at,
       array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
              FROM article_tags at
              WHERE at.article_id = a.id ORDER BY name))::text AS tag_list,
       fv.favorites_count,
       fv.favorited,
       u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following`

ARTICLE_JOINS :: `
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS favorites_count,
           COALESCE(bool_or(f.user_id = $1), false) AS favorited
      FROM favorites f WHERE f.article_id = a.id
  ) fv ON true`

ARTICLE_FULL_SELECT :: ARTICLE_SELECT_COLUMNS + `
  FROM articles a` + ARTICLE_JOINS

LIST_ALL :: ARTICLE_LIST_SELECT + `,
       (SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s) AS total_count
  FROM (
    SELECT a.* FROM articles a
    ORDER BY a.id DESC
    OFFSET $3 LIMIT 100
  ) a
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS favorites_count,
           COALESCE(bool_or(f.user_id = $1), false) AS favorited
      FROM favorites f WHERE f.article_id = a.id
  ) fv ON true
  ORDER BY a.id DESC LIMIT $2`
COUNT_ALL :: `SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s`

LIST_BY_TAG :: ARTICLE_LIST_SELECT + `,
       (SELECT count(*) FROM (SELECT 1 FROM article_tags at
         WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) AS total_count
  FROM (
    SELECT a.* FROM articles a
    WHERE a.id IN (SELECT at.article_id FROM article_tags at
      WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4))
    ORDER BY a.id DESC
    OFFSET $3 LIMIT 100
  ) a
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS favorites_count,
           COALESCE(bool_or(f.user_id = $1), false) AS favorited
      FROM favorites f WHERE f.article_id = a.id
  ) fv ON true
  ORDER BY a.id DESC LIMIT $2`
COUNT_BY_TAG :: `SELECT count(*) FROM (SELECT 1 FROM article_tags at
       WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`

LIST_BY_AUTHOR :: ARTICLE_LIST_SELECT + `,
       (SELECT count(*) FROM (SELECT 1 FROM articles a
         WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) LIMIT 1000) s) AS total_count
  FROM (
    SELECT a.* FROM articles a
    WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)
    ORDER BY a.id DESC
    OFFSET $3 LIMIT 100
  ) a
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS favorites_count,
           COALESCE(bool_or(f.user_id = $1), false) AS favorited
      FROM favorites f WHERE f.article_id = a.id
  ) fv ON true
  ORDER BY a.id DESC LIMIT $2`
COUNT_BY_AUTHOR :: `SELECT count(*) FROM (SELECT 1 FROM articles a
       WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`

LIST_BY_FAVORITE :: ARTICLE_LIST_SELECT + `,
       (SELECT count(*) FROM (SELECT 1 FROM favorites f
         WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) AS total_count
  FROM (
    SELECT a.* FROM articles a
    WHERE a.id IN (SELECT f.article_id FROM favorites f
      WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4))
    ORDER BY a.id DESC
    OFFSET $3 LIMIT 100
  ) a
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS favorites_count,
           COALESCE(bool_or(f.user_id = $1), false) AS favorited
      FROM favorites f WHERE f.article_id = a.id
  ) fv ON true
  ORDER BY a.id DESC LIMIT $2`
COUNT_BY_FAVORITE :: `SELECT count(*) FROM (SELECT 1 FROM favorites f
       WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`

LIST_FEED :: ARTICLE_LIST_SELECT + `,
       (SELECT count(*) FROM (SELECT 1 FROM articles a
         WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) AS total_count
  FROM (
    SELECT a.* FROM (
      SELECT a2.id
        FROM follows fo
        CROSS JOIN LATERAL (
          SELECT a2.id FROM articles a2
          WHERE a2.author_id = fo.followee_id
          ORDER BY a2.id DESC
          LIMIT LEAST($2::bigint + $3::bigint, 1000)
        ) a2
       WHERE fo.follower_id = $1
       ORDER BY a2.id DESC
       LIMIT LEAST($2::bigint + $3::bigint, 100)
       OFFSET $3::bigint
    ) ids JOIN articles a ON a.id = ids.id
    ORDER BY a.id DESC
    LIMIT $2
  ) a
  JOIN users u ON u.id = a.author_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS favorites_count,
           COALESCE(bool_or(f.user_id = $1), false) AS favorited
      FROM favorites f WHERE f.article_id = a.id
  ) fv ON true
  ORDER BY a.id DESC`
COUNT_FEED :: `SELECT count(*) FROM (SELECT 1 FROM articles a
       WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s`

ARTICLE_BY_SLUG :: ARTICLE_FULL_SELECT + ` WHERE a.slug = $2`
ARTICLE_BY_ID :: ARTICLE_FULL_SELECT + ` WHERE a.id = $2`
FAVORITE_ARTICLE :: `
WITH target AS (SELECT id FROM articles WHERE slug = $2),
     fav AS (
       INSERT INTO favorites (user_id, article_id)
       SELECT $1, id FROM target WHERE $3::boolean
       ON CONFLICT DO NOTHING
       RETURNING 1
     ),
     unfav AS (
       DELETE FROM favorites f
        USING target t
        WHERE NOT $3::boolean AND f.user_id = $1 AND f.article_id = t.id
       RETURNING 1
     )
SELECT a.id, a.slug, a.title, a.description, a.body,
       a.created_at AT TIME ZONE 'UTC' AS created_at,
       a.updated_at AT TIME ZONE 'UTC' AS updated_at,
       array_to_json(ARRAY(SELECT (SELECT t2.name FROM tags t2 WHERE t2.id = at.tag_id) AS name
              FROM article_tags at
              WHERE at.article_id = a.id ORDER BY name))::text AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)
         + (SELECT count(*) FROM fav) - (SELECT count(*) FROM unfav) AS favorites_count,
       $3::boolean AS favorited,
       u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM target t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id`
FOLLOW_PROFILE :: `
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     followed AS (
       INSERT INTO follows (follower_id, followee_id)
       SELECT $1, id FROM target WHERE $3::boolean
       ON CONFLICT DO NOTHING
     ),
     unfollowed AS (
       DELETE FROM follows f
        USING target t
        WHERE NOT $3::boolean AND f.follower_id = $1 AND f.followee_id = t.id
     )
SELECT id, username, bio, image, $3::boolean AS following FROM target`

INSERT_ARTICLE :: `INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id, slug`

INSERT_TAGS :: `INSERT INTO tags (name)
SELECT DISTINCT value FROM jsonb_array_elements_text($1::jsonb)
ON CONFLICT (name) DO NOTHING`

INSERT_ARTICLE_TAGS :: `INSERT INTO article_tags (article_id, tag_id)
SELECT $1::bigint, t.id
  FROM tags t
  JOIN (SELECT DISTINCT value AS name FROM jsonb_array_elements_text($2::jsonb)) n
    ON n.name = t.name
ON CONFLICT DO NOTHING`

UPDATE_ARTICLE :: `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug
                   ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1
RETURNING slug`

ARTICLE_OWNER :: `SELECT id, author_id FROM articles WHERE slug = $1`
ARTICLE_ID_BY_SLUG :: `SELECT id FROM articles WHERE slug = $1`

PROFILE_BY_USERNAME :: `SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2`

PROFILE_BY_ID :: `SELECT id, username, bio, image FROM users WHERE id = $1`

USER_BY_ID :: `SELECT id, username, email, bio, image FROM users WHERE id = $1`
USER_BY_EMAIL :: `SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1`

REGISTER_USER :: `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image,
       created_at AT TIME ZONE 'UTC' AS created_at`

UPDATE_USER :: `UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image`

LIST_COMMENTS :: `SELECT c.id, c.body,
       c.created_at AT TIME ZONE 'UTC' AS created_at,
       c.updated_at AT TIME ZONE 'UTC' AS updated_at,
       u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
  FROM articles a
  LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
               FROM comments c WHERE c.article_id = a.id
               ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
  LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = $2
 ORDER BY c.created_at DESC, c.id DESC`

CREATE_COMMENT :: `WITH t AS (SELECT id FROM articles WHERE slug = $1),
       c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t
       RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body,
       c.created_at AT TIME ZONE 'UTC' AS created_at,
       c.updated_at AT TIME ZONE 'UTC' AS updated_at,
       u.id, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`

COMMENT_AUTHOR :: `WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
              WHERE c.id = $1 AND a.slug = $2),
       w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t`

TAGS :: `SELECT array_to_json(ARRAY(SELECT name FROM tags ORDER BY name))::text`

SET_FOLLOW :: `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`
DELETE_FOLLOW :: `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`
SET_FAVORITE :: `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`
DELETE_FAVORITE :: `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`
DELETE_ARTICLE :: `DELETE FROM articles WHERE id = $1`

stmt_name :: proc(s: Stmt) -> cstring {
	switch s {
	case .ArticleBySlug: return "article_by_slug"
	case .ArticleById: return "article_by_id"
	case .FavoriteArticle: return "favorite_article"
	case .FollowProfile: return "follow_profile"
	case .ListAll: return "list_all"
	case .ListByTag: return "list_by_tag"
	case .ListByAuthor: return "list_by_author"
	case .ListByFavorited: return "list_by_favorited"
	case .ListFeed: return "list_feed"
	case .CountAll: return "count_all"
	case .CountByTag: return "count_by_tag"
	case .CountByAuthor: return "count_by_author"
	case .CountByFavorited: return "count_by_favorited"
	case .CountFeed: return "count_feed"
	case .InsertArticle: return "insert_article"
	case .InsertTags: return "insert_tags"
	case .InsertArticleTags: return "insert_article_tags"
	case .UpdateArticle: return "update_article"
	case .ArticleOwner: return "article_owner"
	case .ArticleIdBySlug: return "article_id_by_slug"
	case .ProfileByUsername: return "profile_by_username"
	case .ProfileById: return "profile_by_id"
	case .UserById: return "user_by_id"
	case .UserByEmail: return "user_by_email"
	case .RegisterUser: return "register_user"
	case .UpdateUser: return "update_user"
	case .ListComments: return "list_comments"
	case .CreateComment: return "create_comment"
	case .CommentAuthor: return "comment_author"
	case .Tags: return "tags"
	case .SetFollow: return "set_follow"
	case .DeleteFollow: return "delete_follow"
	case .SetFavorite: return "set_favorite"
	case .DeleteFavorite: return "delete_favorite"
	case .DeleteArticle: return "delete_article"
	}
	return ""
}

stmt_query :: proc(s: Stmt) -> string {
	switch s {
	case .ArticleBySlug: return ARTICLE_BY_SLUG
	case .ArticleById: return ARTICLE_BY_ID
	case .FavoriteArticle: return FAVORITE_ARTICLE
	case .FollowProfile: return FOLLOW_PROFILE
	case .ListAll: return LIST_ALL
	case .ListByTag: return LIST_BY_TAG
	case .ListByAuthor: return LIST_BY_AUTHOR
	case .ListByFavorited: return LIST_BY_FAVORITE
	case .ListFeed: return LIST_FEED
	case .CountAll: return COUNT_ALL
	case .CountByTag: return COUNT_BY_TAG
	case .CountByAuthor: return COUNT_BY_AUTHOR
	case .CountByFavorited: return COUNT_BY_FAVORITE
	case .CountFeed: return COUNT_FEED
	case .InsertArticle: return INSERT_ARTICLE
	case .InsertTags: return INSERT_TAGS
	case .InsertArticleTags: return INSERT_ARTICLE_TAGS
	case .UpdateArticle: return UPDATE_ARTICLE
	case .ArticleOwner: return ARTICLE_OWNER
	case .ArticleIdBySlug: return ARTICLE_ID_BY_SLUG
	case .ProfileByUsername: return PROFILE_BY_USERNAME
	case .ProfileById: return PROFILE_BY_ID
	case .UserById: return USER_BY_ID
	case .UserByEmail: return USER_BY_EMAIL
	case .RegisterUser: return REGISTER_USER
	case .UpdateUser: return UPDATE_USER
	case .ListComments: return LIST_COMMENTS
	case .CreateComment: return CREATE_COMMENT
	case .CommentAuthor: return COMMENT_AUTHOR
	case .Tags: return TAGS
	case .SetFollow: return SET_FOLLOW
	case .DeleteFollow: return DELETE_FOLLOW
	case .SetFavorite: return SET_FAVORITE
	case .DeleteFavorite: return DELETE_FAVORITE
	case .DeleteArticle: return DELETE_ARTICLE
	}
	return ""
}

prepare_statements :: proc(conn: pq.Conn) -> bool {
	if !db_exec_simple(conn, "SET jit = off; SET plan_cache_mode = force_generic_plan; SET max_parallel_workers_per_gather = 0; SET DateStyle = 'ISO, MDY'; SET TimeZone = 'UTC'") {
		return false
	}
	for s in STMT_ALL {
		q := strings.clone_to_cstring(stmt_query(s), context.temp_allocator)
		res := pq.prepare(conn, stmt_name(s), q, 0, nil)
		ok := db_ok(res)
		db_clear(res)
		if !ok {
			return false
		}
	}
	return true
}

db_exec_stmt :: proc(conn: pq.Conn, stmt: Stmt, params: []Maybe(string), allocator := context.temp_allocator) -> pq.Result {
	values := make([][^]byte, len(params), allocator)
	for p, i in params {
		if v, ok := p.?; ok {
			values[i] = ([^]byte)(strings.clone_to_cstring(v, allocator))
		} else {
			values[i] = nil
		}
	}

	values_ptr: [^][^]byte
	if len(values) > 0 {
		values_ptr = &values[0]
	}

	return pq.exec_prepared(conn, stmt_name(stmt), i32(len(values)), values_ptr, nil, nil, .Text)
}

db_ok :: proc(res: pq.Result) -> bool {
	if res == nil {
		return false
	}
	status := pq.result_status(res)
	return status == .Command_OK || status == .Tuples_OK
}

db_clear :: proc(res: pq.Result) {
	if res != nil {
		pq.clear(res)
	}
}

db_is_unique_violation :: proc(res: pq.Result) -> bool {
	if res == nil || pq.result_status(res) != .Fatal_Error {
		return false
	}
	state := pq.result_error_field(res, .SQL_State)
	return state != nil && runtime.cstring_to_string(state) == "23505"
}

db_exec_simple :: proc(conn: pq.Conn, sql: cstring) -> bool {
	res := pq.exec(conn, sql)
	ok := db_ok(res)
	db_clear(res)
	return ok
}

db_begin :: proc(conn: pq.Conn) -> bool {
	return db_exec_simple(conn, "BEGIN")
}

db_commit :: proc(conn: pq.Conn) -> bool {
	return db_exec_simple(conn, "COMMIT")
}

db_rollback :: proc(conn: pq.Conn) -> bool {
	return db_exec_simple(conn, "ROLLBACK")
}

read_text :: proc(res: pq.Result, row, col: i32, allocator := context.temp_allocator) -> Maybe(string) {
	if pq.get_is_null(res, row, col) {
		return nil
	}
	ptr := pq.get_value(res, row, col)
	n := int(pq.get_length(res, row, col))
	if ptr == nil || n < 0 {
		return nil
	}
	view := ptr[:n]
	return strings.clone(transmute(string)view, allocator)
}

read_timestamp :: proc(res: pq.Result, row, col: i32, allocator := context.temp_allocator) -> string {
	if pq.get_is_null(res, row, col) {
		return ""
	}
	ptr := pq.get_value(res, row, col)
	n := int(pq.get_length(res, row, col))
	if ptr == nil || n < 19 {
		return read_text(res, row, col, allocator).? or_else ""
	}

	out := make([]byte, 24, allocator)
	copy(out[0:10], ptr[0:10])
	out[10] = 'T'
	copy(out[11:19], ptr[11:19])
	out[19] = '.'

	frac := 0
	if n > 20 && ptr[19] == '.' {
		frac = n - 20
	}
	for i in 0..<3 {
		out[20 + i] = '0'
		if i < frac {
			out[20 + i] = ptr[20 + i]
		}
	}
	out[23] = 'Z'
	return string(out)
}

read_i64 :: proc(res: pq.Result, row, col: i32) -> i64 {
	s := read_text(res, row, col).? or_else "0"
	n, _ := parse_uint_decimal(s)
	return n
}

read_bool :: proc(res: pq.Result, row, col: i32) -> bool {
	s := read_text(res, row, col).? or_else "f"
	return s == "t"
}

read_article :: proc(res: pq.Result, row: i32, full: bool, allocator := context.temp_allocator) -> Article_Row {
	x: Article_Row
	x.id = read_i64(res, row, 0)
	x.slug = read_text(res, row, 1, allocator).? or_else ""
	x.title = read_text(res, row, 2, allocator).? or_else ""
	x.description = read_text(res, row, 3, allocator).? or_else ""
	if full {
		x.body = read_text(res, row, 4, allocator).? or_else ""
		x.created_at = read_timestamp(res, row, 5, allocator)
		x.updated_at = read_timestamp(res, row, 6, allocator)
		x.tag_list_json = read_text(res, row, 7, allocator).? or_else "[]"
		x.favorites_count = read_i64(res, row, 8)
		x.favorited = read_bool(res, row, 9)
		x.author_id = read_i64(res, row, 10)
		x.author_username = read_text(res, row, 11, allocator).? or_else ""
		x.author_bio = read_text(res, row, 12, allocator)
		x.author_image = read_text(res, row, 13, allocator)
		x.following = read_bool(res, row, 14)
	} else {
		x.created_at = read_timestamp(res, row, 4, allocator)
		x.updated_at = read_timestamp(res, row, 5, allocator)
		x.tag_list_json = read_text(res, row, 6, allocator).? or_else "[]"
		x.favorites_count = read_i64(res, row, 7)
		x.favorited = read_bool(res, row, 8)
		x.author_id = read_i64(res, row, 9)
		x.author_username = read_text(res, row, 10, allocator).? or_else ""
		x.author_bio = read_text(res, row, 11, allocator)
		x.author_image = read_text(res, row, 12, allocator)
		x.following = read_bool(res, row, 13)
		x.total_count = read_i64(res, row, 14)
	}
	return x
}

read_comment :: proc(res: pq.Result, row: i32, allocator := context.temp_allocator, has_following := true) -> Comment_Row {
	c: Comment_Row
	c.id = read_i64(res, row, 0)
	c.body = read_text(res, row, 1, allocator).? or_else ""
	c.created_at = read_timestamp(res, row, 2, allocator)
	c.updated_at = read_timestamp(res, row, 3, allocator)
	c.author_id = read_i64(res, row, 4)
	c.author_username = read_text(res, row, 5, allocator).? or_else ""
	c.author_bio = read_text(res, row, 6, allocator)
	c.author_image = read_text(res, row, 7, allocator)
	if has_following {
		c.following = read_bool(res, row, 8)
	}
	return c
}

read_profile :: proc(res: pq.Result, row: i32, allocator := context.temp_allocator) -> Profile_Row {
	p: Profile_Row
	p.id = read_i64(res, row, 0)
	p.username = read_text(res, row, 1, allocator).? or_else ""
	p.bio = read_text(res, row, 2, allocator)
	p.image = read_text(res, row, 3, allocator)
	p.following = read_bool(res, row, 4)
	return p
}

read_user :: proc(res: pq.Result, row: i32, allocator := context.temp_allocator) -> User_Row {
	u: User_Row
	u.id = read_i64(res, row, 0)
	u.username = read_text(res, row, 1, allocator).? or_else ""
	u.email = read_text(res, row, 2, allocator).? or_else ""
	u.bio = read_text(res, row, 3, allocator)
	u.image = read_text(res, row, 4, allocator)
	return u
}

db_get_article_by_slug :: proc(conn: pq.Conn, slug: string, viewer: i64, allocator := context.temp_allocator) -> (row: Article_Row, found: bool, ok: bool) {
	viewer_str := fmt.tprintf("%d", viewer)
	res := db_exec_stmt(conn, .ArticleBySlug, []Maybe(string){viewer_str, slug}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	return read_article(res, 0, true, allocator), true, true
}

db_get_article_by_id :: proc(conn: pq.Conn, id, viewer: i64, allocator := context.temp_allocator) -> (row: Article_Row, found: bool, ok: bool) {
	viewer_str := fmt.tprintf("%d", viewer)
	id_str := fmt.tprintf("%d", id)
	res := db_exec_stmt(conn, .ArticleById, []Maybe(string){viewer_str, id_str}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	return read_article(res, 0, true, allocator), true, true
}

db_list_articles :: proc(conn: pq.Conn, viewer: i64, mode: List_Mode, filter: string, limit, offset: i64, allocator := context.temp_allocator) -> (rows: []Article_Row, ok: bool) {
	stmt: Stmt
	params: []Maybe(string)
	viewer_str := fmt.tprintf("%d", viewer)
	limit_str := fmt.tprintf("%d", limit)
	offset_str := fmt.tprintf("%d", offset)

	switch mode {
	case .All:
		stmt = .ListAll
		params = []Maybe(string){viewer_str, limit_str, offset_str}
	case .Tag:
		stmt = .ListByTag
		params = []Maybe(string){viewer_str, limit_str, offset_str, filter}
	case .Author:
		stmt = .ListByAuthor
		params = []Maybe(string){viewer_str, limit_str, offset_str, filter}
	case .Favorited:
		stmt = .ListByFavorited
		params = []Maybe(string){viewer_str, limit_str, offset_str, filter}
	case .Feed:
		stmt = .ListFeed
		params = []Maybe(string){viewer_str, limit_str, offset_str}
	}

	res := db_exec_stmt(conn, stmt, params, allocator)
	if !db_ok(res) {
		db_clear(res)
		return nil, false
	}
	defer db_clear(res)

	n := pq.n_tuples(res)
	out := make([dynamic]Article_Row, 0, n, allocator)
	for i in 0..<n {
		append(&out, read_article(res, i, false, allocator))
	}
	return out[:], true
}

db_count_articles :: proc(conn: pq.Conn, viewer: i64, mode: List_Mode, filter: string, allocator := context.temp_allocator) -> (n: i64, ok: bool) {
	stmt: Stmt
	params: []Maybe(string)
	viewer_str := fmt.tprintf("%d", viewer)

	switch mode {
	case .All:
		stmt = .CountAll
		params = nil
	case .Tag:
		stmt = .CountByTag
		params = []Maybe(string){filter}
	case .Author:
		stmt = .CountByAuthor
		params = []Maybe(string){filter}
	case .Favorited:
		stmt = .CountByFavorited
		params = []Maybe(string){filter}
	case .Feed:
		stmt = .CountFeed
		params = []Maybe(string){viewer_str}
	}

	res := db_exec_stmt(conn, stmt, params, allocator)
	if !db_ok(res) {
		db_clear(res)
		return 0, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return 0, false
	}
	s := read_text(res, 0, 0, allocator).? or_else "0"
	value, parsed := parse_uint_decimal(s)
	return value, parsed
}

db_create_article :: proc(conn: pq.Conn, author_id: i64, title, description, body, tags_json: string, allocator := context.temp_allocator) -> (id: i64, slug: string, ok: bool) {
	if !db_begin(conn) {
		return 0, "", false
	}

	author_str := fmt.tprintf("%d", author_id)
	res := db_exec_stmt(conn, .InsertArticle, []Maybe(string){author_str, title, description, body}, allocator)
	if !db_ok(res) {
		db_clear(res)
		db_rollback(conn)
		return 0, "", false
	}
	if pq.n_tuples(res) != 1 {
		db_clear(res)
		db_rollback(conn)
		return 0, "", false
	}
	id = read_i64(res, 0, 0)
	slug = read_text(res, 0, 1, allocator).? or_else ""
	db_clear(res)

	if len(tags_json) > 2 {
		id_str := fmt.tprintf("%d", id)
		tag_res := db_exec_stmt(conn, .InsertTags, []Maybe(string){tags_json}, allocator)
		if !db_ok(tag_res) {
			db_clear(tag_res)
			db_rollback(conn)
			return 0, "", false
		}
		db_clear(tag_res)

		link_res := db_exec_stmt(conn, .InsertArticleTags, []Maybe(string){id_str, tags_json}, allocator)
		if !db_ok(link_res) {
			db_clear(link_res)
			db_rollback(conn)
			return 0, "", false
		}
		db_clear(link_res)
	}

	if !db_commit(conn) {
		db_rollback(conn)
		return 0, "", false
	}
	return id, slug, true
}

db_update_article :: proc(conn: pq.Conn, article_id: i64, title, description, body: Maybe(string), allocator := context.temp_allocator) -> (slug: string, found: bool, ok: bool) {
	id_str := fmt.tprintf("%d", article_id)
	res := db_exec_stmt(conn, .UpdateArticle, []Maybe(string){id_str, title, description, body}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return "", false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return "", false, true
	}
	return read_text(res, 0, 0, allocator).? or_else "", true, true
}

db_article_owner :: proc(conn: pq.Conn, slug: string, allocator := context.temp_allocator) -> (id, author_id: i64, found: bool, ok: bool) {
	res := db_exec_stmt(conn, .ArticleOwner, []Maybe(string){slug}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return 0, 0, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return 0, 0, false, true
	}
	return read_i64(res, 0, 0), read_i64(res, 0, 1), true, true
}

db_article_id :: proc(conn: pq.Conn, slug: string, allocator := context.temp_allocator) -> (id: i64, found: bool, ok: bool) {
	res := db_exec_stmt(conn, .ArticleIdBySlug, []Maybe(string){slug}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return 0, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return 0, false, true
	}
	return read_i64(res, 0, 0), true, true
}

db_get_profile :: proc(conn: pq.Conn, username: string, viewer: i64, allocator := context.temp_allocator) -> (p: Profile_Row, found: bool, ok: bool) {
	viewer_str := fmt.tprintf("%d", viewer)
	res := db_exec_stmt(conn, .ProfileByUsername, []Maybe(string){viewer_str, username}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	return read_profile(res, 0, allocator), true, true
}

db_get_profile_by_id :: proc(conn: pq.Conn, id: i64, allocator := context.temp_allocator) -> (p: Profile_Row, found: bool, ok: bool) {
	id_str := fmt.tprintf("%d", id)
	res := db_exec_stmt(conn, .ProfileById, []Maybe(string){id_str}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	p.id = read_i64(res, 0, 0)
	p.username = read_text(res, 0, 1, allocator).? or_else ""
	p.bio = read_text(res, 0, 2, allocator)
	p.image = read_text(res, 0, 3, allocator)
	return p, true, true
}

db_get_user_by_id :: proc(conn: pq.Conn, id: i64, allocator := context.temp_allocator) -> (u: User_Row, found: bool, ok: bool) {
	id_str := fmt.tprintf("%d", id)
	res := db_exec_stmt(conn, .UserById, []Maybe(string){id_str}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	return read_user(res, 0, allocator), true, true
}

db_get_user_by_email :: proc(conn: pq.Conn, email: string, allocator := context.temp_allocator) -> (u: User_Row, found: bool, ok: bool) {
	res := db_exec_stmt(conn, .UserByEmail, []Maybe(string){email}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	u = read_user(res, 0, allocator)
	u.password_hash = read_text(res, 0, 5, allocator)
	return u, true, true
}

db_register_user :: proc(conn: pq.Conn, username, email, password_hash: string, allocator := context.temp_allocator) -> (u: User_Row, unique: bool, ok: bool) {
	res := db_exec_stmt(conn, .RegisterUser, []Maybe(string){username, email, password_hash}, allocator)
	if db_is_unique_violation(res) {
		db_clear(res)
		return {}, true, false
	}
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) != 1 {
		return {}, false, false
	}
	u = read_user(res, 0, allocator)
	u.created_at = read_timestamp(res, 0, 5, allocator)
	return u, false, true
}

db_update_user :: proc(conn: pq.Conn, id: i64, email, username, password_hash, bio, image: Maybe(string), allocator := context.temp_allocator) -> (u: User_Row, unique: bool, found: bool, ok: bool) {
	id_str := fmt.tprintf("%d", id)
	res := db_exec_stmt(conn, .UpdateUser, []Maybe(string){id_str, email, username, password_hash, bio, image}, allocator)
	if db_is_unique_violation(res) {
		db_clear(res)
		return {}, true, true, false
	}
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, false, true
	}
	return read_user(res, 0, allocator), false, true, true
}

db_list_comments :: proc(conn: pq.Conn, viewer: i64, slug: string, allocator := context.temp_allocator) -> (rows: []Comment_Row, found: bool, ok: bool) {
	viewer_str := fmt.tprintf("%d", viewer)
	res := db_exec_stmt(conn, .ListComments, []Maybe(string){viewer_str, slug}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return nil, false, false
	}
	defer db_clear(res)
	n := pq.n_tuples(res)
	if n == 0 {
		return nil, false, true
	}
	if pq.get_is_null(res, 0, 0) {
		return nil, true, true
	}
	out := make([dynamic]Comment_Row, 0, n, allocator)
	for i in 0..<n {
		append(&out, read_comment(res, i, allocator))
	}
	return out[:], true, true
}

db_create_comment :: proc(conn: pq.Conn, slug: string, author_id: i64, body: string, allocator := context.temp_allocator) -> (c: Comment_Row, found: bool, ok: bool) {
	author_str := fmt.tprintf("%d", author_id)
	res := db_exec_stmt(conn, .CreateComment, []Maybe(string){slug, author_str, body}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	c = read_comment(res, 0, allocator, false)
	return c, true, true
}

db_delete_comment :: proc(conn: pq.Conn, comment_id: i64, slug: string, viewer: i64, allocator := context.temp_allocator) -> (author_id: i64, found: bool, ok: bool) {
	id_str := fmt.tprintf("%d", comment_id)
	viewer_str := fmt.tprintf("%d", viewer)
	res := db_exec_stmt(conn, .CommentAuthor, []Maybe(string){id_str, slug, viewer_str}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return 0, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return 0, false, true
	}
	return read_i64(res, 0, 0), true, true
}

db_tags :: proc(conn: pq.Conn, allocator := context.temp_allocator) -> (tags_json: string, ok: bool) {
	res := db_exec_stmt(conn, .Tags, nil, allocator)
	if !db_ok(res) {
		db_clear(res)
		return "", false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return "[]", true
	}
	return read_text(res, 0, 0, allocator).? or_else "[]", true
}

db_set_follow :: proc(conn: pq.Conn, username: string, viewer: i64, follow: bool, allocator := context.temp_allocator) -> (p: Profile_Row, found: bool, ok: bool) {
	viewer_str := fmt.tprintf("%d", viewer)
	follow_str := "true" if follow else "false"
	res := db_exec_stmt(conn, .FollowProfile, []Maybe(string){viewer_str, username, follow_str}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	return read_profile(res, 0, allocator), true, true
}

db_set_favorite :: proc(conn: pq.Conn, slug: string, viewer: i64, favorite: bool, allocator := context.temp_allocator) -> (row: Article_Row, found: bool, ok: bool) {
	viewer_str := fmt.tprintf("%d", viewer)
	favorite_str := "true" if favorite else "false"
	res := db_exec_stmt(conn, .FavoriteArticle, []Maybe(string){viewer_str, slug, favorite_str}, allocator)
	if !db_ok(res) {
		db_clear(res)
		return {}, false, false
	}
	defer db_clear(res)
	if pq.n_tuples(res) == 0 {
		return {}, false, true
	}
	return read_article(res, 0, true, allocator), true, true
}

db_delete_article :: proc(conn: pq.Conn, id: i64, allocator := context.temp_allocator) -> bool {
	id_str := fmt.tprintf("%d", id)
	res := db_exec_stmt(conn, .DeleteArticle, []Maybe(string){id_str}, allocator)
	ok := db_ok(res)
	db_clear(res)
	return ok
}


