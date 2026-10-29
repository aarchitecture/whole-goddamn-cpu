import re, sys, os
# Copy business files byte-for-byte and extract named blocks from
# http.mbt/main.mbt into the generated handler package.
SRC = sys.argv[1]
OUT = sys.argv[2]
os.makedirs(OUT, exist_ok=True)
for f in ["auth.mbt", "users.mbt", "articles.mbt", "comments.mbt", "sql.mbt", "util.mbt", "jsonw.mbt"]:
    open(os.path.join(OUT, f), "wb").write(open(os.path.join(SRC, f), "rb").read())
for f in ["pwhash_base64.mbt", "pwhash_bcrypt.mbt", "pwhash_bcrypt_core.mbt",
          "pwhash_blowfish.mbt", "pwhash_blowfish_constants.mbt"]:
    open(os.path.join(OUT, f), "wb").write(open(os.path.join(SRC, f), "rb").read())

def blocks(path):
    text = open(path, encoding="utf-8").read()
    # split on ///| doc comments
    parts = re.split(r'(?m)^///\|', text)
    out = {}
    for p in parts[1:]:
        blk = "///|" + p
        m = re.search(r'(?:pub )?(?:async )?(?:fn|struct|suberror|enum|trait|let|const) (\w+)', blk)
        if m:
            out[m.group(1)] = blk.rstrip() + "\n"
    return out

hb = blocks(os.path.join(SRC, "http.mbt"))
mb = blocks(os.path.join(SRC, "main.mbt"))
want_http = ["App", "Resp", "json_resp", "raw_json_resp", "err_resp", "no_content", "is_unique_violation", "auth", "dispatch"]
want_main = ["DbUrl", "ConfigError", "env_or", "parse_database_url"]
with open(os.path.join(OUT, "app_shared.mbt"), "w", encoding="utf-8") as f:
    for n in want_http:
        f.write(hb[n] + "\n")
    for n in want_main:
        f.write(mb[n] + "\n")
print("extracted", [n for n in want_http if n in hb], [n for n in want_main if n in mb])
