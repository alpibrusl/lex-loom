# A shell string as a JSON argument for `lex run`. Newlines and tabs must be
# escaped, not passed through: a document read from stdin is multi-line, and
# lex refuses a raw control character inside a JSON string.
jsonarg() {
  printf '"%s"' "$(printf '%s' "${1-}" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}')"
}
# `lex run` prints main's Int return on its own final line. That value IS the
# exit code this tool should carry, so it is taken rather than discarded.
run_lex() {
  local out rc
  out=$("$@" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  rc=$(printf '%s\n' "$out" | tail -1)
  case "$rc" in
    ''|*[!0-9]*) printf '%s\n' "$out"; return 1 ;;
    *) printf '%s\n' "$out" | sed -e '$d'; return "$rc" ;;
  esac
}
