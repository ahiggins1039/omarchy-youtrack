#!/usr/bin/env bash
# Exercises youtrack-fetch against a stubbed curl, so no network or token is
# needed. Run with: bash tests/youtrack-fetch.test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../youtrack-fetch"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
check() { # name, jq filter that must be true, json
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "     got: $3"; failures=$((failures + 1))
  fi
}

# A fake curl that prints $STUB_BODY then "\n$STUB_STATUS", like `curl -w`,
# and records its arguments so the request itself can be checked.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGS"
printf '%s\n%s' "$STUB_BODY" "${STUB_STATUS:-200}"
STUB
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" STUB_ARGS="$work/args"

config="$work/youtrack.env"
cat >"$config" <<'CFG'
YOUTRACK_URL="https://example.youtrack.cloud/"
YOUTRACK_TOKEN="perm:FAKE"
CFG
export YOUTRACK_CONFIG="$config"

issues='[
  {"idReadable":"ABC-1","summary":"Crash","updated":20,"project":{"shortName":"ABC"},
   "customFields":[{"name":"Priority","value":{"name":"Critical"}},{"name":"State","value":{"name":"Open"}},
                   {"name":"Severity","value":[{"name":"High"}]},{"name":"Type","value":null}]},
  {"idReadable":"ABC-2","summary":"Typo","updated":10,"project":{"shortName":"ABC"},"customFields":[]}
]'

out=$(STUB_BODY="$issues" bash "$script")
check "parses issues" '.ok and (.issues | length) == 2' "$out"
check "reads Priority by default" '.issues[0].priority == "Critical"' "$out"
check "unset priority becomes None" '.issues[1].priority == "None"' "$out"
check "null field becomes empty" '.issues[0].type == ""' "$out"
check "trims the base URL's trailing slash" '.issues[0].url == "https://example.youtrack.cloud/issue/ABC-1"' "$out"
check "default query" '.query == "for: me #Unresolved"' "$out"
grep -qx 'Authorization: Bearer perm:FAKE' "$STUB_ARGS" && echo "ok   sends the token" || { echo "FAIL sends the token"; failures=$((failures + 1)); }

out=$(STUB_BODY="$issues" bash "$script" 'project: ABC' 'Severity')
check "priority field argument, multi-value field" '.issues[0].priority == "High" and .query == "project: ABC"' "$out"

out=$(echo 'YOUTRACK_PRIORITY_FIELD="State"' >>"$config"; STUB_BODY="$issues" bash "$script")
check "YOUTRACK_PRIORITY_FIELD from config" '.issues[0].priority == "Open"' "$out"

out=$(STUB_BODY='{"error":"invalid_query","error_description":"Bad query"}' STUB_STATUS=400 bash "$script")
check "HTTP error reports YouTrack's message" '(.ok | not) and .error == "YouTrack returned HTTP 400: Bad query"' "$out"

out=$(STUB_BODY='<html>' bash "$script")
check "unparseable body" '(.ok | not) and (.error | test("parse"))' "$out"

out=$(YOUTRACK_CONFIG="$work/missing.env" bash "$script")
check "missing config" '(.ok | not) and (.error | test("Cannot read"))' "$out"

printf 'YOUTRACK_URL="https://x"\n' >"$work/notoken.env"
out=$(YOUTRACK_CONFIG="$work/notoken.env" bash "$script")
check "missing token" '(.ok | not) and (.error | test("YOUTRACK_TOKEN"))' "$out"

echo
(( failures == 0 )) && echo "all passed" || { echo "$failures failed"; exit 1; }
