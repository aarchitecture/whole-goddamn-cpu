moon_update() {
  local moon="$1" i
  for i in 1 2 3 4 5 6 7 8; do
    if GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=15 timeout 120 "$moon" update; then
      return 0
    fi
    echo "moon update attempt $i failed; retrying" >&2
    sleep 2
  done
  echo "moon update failed after 8 attempts" >&2
  return 1
}
