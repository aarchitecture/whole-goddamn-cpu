// SQL derived from SPEC.md / examples/go: same results, batched per request
// kind; created_at/updated_at are formatted server-side as RFC 3339 UTC
// strings with millisecond precision via to_char.

///|
let ts_created : String = "to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS created_at"

///|
let ts_updated : String = "to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS updated_at"

///|
let tag_list_col : String = "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) " +
  "FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list"

///|
let following_col : String = "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following"

///|
let article_list_columns : String = "SELECT a.id, a.slug, a.title, a.description, " +
  ts_created +
  ", " +
  ts_updated +
  ", " +
  tag_list_col +
  ", " +
  "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " +
  "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, " +
  "u.username, u.bio, u.image, " +
  following_col

///|
let article_list_from : String = " FROM articles a JOIN users u ON u.id = a.author_id"

///|
let article_full_select : String = "SELECT a.id, a.slug, a.title, a.description, a.body, " +
  ts_created +
  ", " +
  ts_updated +
  ", " +
  tag_list_col +
  ", " +
  "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " +
  "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, " +
  "u.username, u.bio, u.image, " +
  following_col +
  " FROM articles a JOIN users u ON u.id = a.author_id"

///|
fn capped_count(from_where : String) -> String {
  "CASE WHEN EXISTS (SELECT 1 FROM " +
  from_where +
  " OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM (SELECT 1 FROM " +
  from_where +
  " LIMIT 1000) s) END"
}

///|
/// Global list for many requests in one statement (see Pool::batched_query):
/// $1 viewers, $2 limits, $3 offsets. The count is correlated with the request
/// row and kept in an OFFSET 0 subquery so it runs once per request; an empty
/// page still yields one row (NULL article columns) carrying the count.
let list_all_batched : String = "SELECT x.*, c.n AS articles_count, r.i " +
  "FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(viewer, lim, off, i) " +
  "CROSS JOIN LATERAL (SELECT " +
  capped_count("articles ca WHERE r.i > 0") +
  " AS n OFFSET 0) c " +
  "LEFT JOIN LATERAL (" +
  article_list_columns.replace_all(old="$1", new="r.viewer") +
  article_list_from +
  " WHERE a.id = ANY(ARRAY(SELECT pa.id FROM articles pa ORDER BY pa.id DESC LIMIT r.lim OFFSET r.off)) ORDER BY a.id DESC" +
  ") x ON true ORDER BY r.i, x.id DESC"

///|
fn list_batched(
  columns : String,
  keyed : Bool,
  count : String,
  ids : String,
) -> String {
  let unnest = if keyed {
    "FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(viewer, lim, off, key, i) "
  } else {
    "FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(viewer, lim, off, i) "
  }
  "SELECT x.*, c.n AS articles_count, r.i " +
  unnest +
  "CROSS JOIN LATERAL (SELECT " +
  count +
  " AS n OFFSET 0) c LEFT JOIN LATERAL (" +
  columns.replace_all(old="$1", new="r.viewer") +
  article_list_from +
  " WHERE a.id = ANY(ARRAY(" +
  ids +
  ")) ORDER BY a.id DESC) x ON true ORDER BY r.i, x.id DESC"
}

///|
let list_tag_batched : String = list_batched(
  article_list_columns,
  true,
  capped_count(
    "article_tags cat WHERE cat.tag_id = (SELECT ct.id FROM tags ct WHERE ct.name = r.key)",
  ),
  "SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key) ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off",
)

///|
let list_author_batched : String = list_batched(
  article_list_columns,
  true,
  "(SELECT count(*) FROM (SELECT 1 FROM articles ca WHERE ca.author_id = (SELECT cu.id FROM users cu WHERE cu.username = r.key) LIMIT 1000) s)",
  "SELECT pa.id FROM articles pa WHERE pa.author_id = (SELECT au.id FROM users au WHERE au.username = r.key) ORDER BY pa.id DESC LIMIT r.lim OFFSET r.off",
)

///|
let list_favorite_batched : String = list_batched(
  article_list_columns,
  true,
  "(SELECT count(*) FROM (SELECT 1 FROM favorites cf WHERE cf.user_id = (SELECT cfu.id FROM users cfu WHERE cfu.username = r.key) LIMIT 1000) s)",
  "SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.key) ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off",
)

///|
let list_feed_batched : String = list_batched(
  article_list_columns.replace_all(old=following_col, new="true AS following"),
  false,
  "(SELECT count(*) FROM (SELECT 1 FROM articles ca WHERE ca.author_id IN (SELECT cfo.followee_id FROM follows cfo WHERE cfo.follower_id = r.viewer) LIMIT 1000) s)",
  "SELECT fx.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (r.lim + r.off)) fx WHERE fo.follower_id = r.viewer ORDER BY fx.id DESC LIMIT r.lim OFFSET r.off",
)

///|
let comments_by_slug_batched : String = "SELECT a.id, x.id, x.body, x.created_at, x.updated_at, " +
  "x.username, x.bio, x.image, x.following, r.i " +
  "FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, i) " +
  "JOIN articles a ON a.slug = r.slug " +
  "CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer) AS ids OFFSET 0) fl " +
  "LEFT JOIN LATERAL (" +
  "SELECT c.id, c.body, " +
  comment_ts_created +
  ", " +
  comment_ts_updated +
  ", u.username, u.bio, u.image, " +
  "(c.author_id = ANY (fl.ids)) AS following, " +
  "c.created_at AS sort_created " +
  "FROM comments c JOIN users u ON u.id = c.author_id " +
  "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100" +
  ") x ON true ORDER BY r.i, x.sort_created DESC, x.id DESC"

///|
let article_by_slug_batched : String = "SELECT x.*, r.i " +
  "FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, i) " +
  "CROSS JOIN LATERAL (" +
  article_full_select.replace_all(old="$1", new="r.viewer") +
  " WHERE a.slug = r.slug) x ORDER BY r.i"

///|
let profile_batched : String = "SELECT u.id, u.username, u.bio, u.image, " +
  "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = u.id) AS following, r.i " +
  "FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, username, i) " +
  "JOIN users u ON u.username = r.username ORDER BY r.i"

///|
let tags_batched : String = "SELECT t.tags, r.i FROM unnest($1::int8[]) WITH ORDINALITY AS r(d, i) " +
  "CROSS JOIN LATERAL (SELECT array_agg(name ORDER BY name) AS tags FROM tags WHERE r.i > 0) t ORDER BY r.i"

///|
let article_by_id : String = article_full_select + " WHERE a.id = $2"

///|
let insert_article : String = "INSERT INTO articles (id, slug, author_id, title, description, body) " +
  "SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 " +
  "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id"

///|
let insert_tags : String = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"

///|
let insert_article_tags : String = "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"

///|
let update_article_sql : String = "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body), " +
  "slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, " +
  "updated_at = now() WHERE id = $1"
