#!/bin/bash
# Offline checks for the luna-send-pub capture guard. No TV, no network.

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
bin="${work}/bin"
mkdir -p -- "${bin}"
trap 'rm -rf -- "${work}"' EXIT

cat >"${bin}/fsync" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${bin}/fsync" "${root}/tests/mock-luna-send-pub.py"
cp -- "${root}/tests/mock-luna-send-pub.py" "${bin}/luna-send-pub"
chmod 0755 "${bin}/luna-send-pub"

export PATH="${bin}:${PATH}"
export LUNA_MOCK_LOG="${work}/luna-calls.jsonl"
export AUTOROOT_UNDER_TEST=1
unset LUNA_MOCK_EMPTY LUNA_MOCK_FORMAT LUNA_MOCK_STDERR LUNA_MOCK_STATUS || true

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

# --- parser: old line-anchored expression vs the one in the script ---
old_pat='s/^\s*"sdkVersion":\s*"\([0-9.]\+\)"\s*$/\1/p'
parse_old() {
    printf '%s\n' "$1" | sed -n -e "${old_pat}" | head -n 1
}

pretty='{
    "modelName": "49UH770V-ZA",
    "firmwareVersion": "05.70.55",
    "returnValue": true,
    "sdkVersion": "3.4.0"
}'
compact='{ "returnValue": true, "sdkVersion": "3.4.0", "firmwareVersion": "05.70.55" }'
spaced='{
    "sdkVersion" : "3.4.0"
}'

assert_eq "$(parse_old "${pretty}")" "3.4.0" "old sed matches pretty sdk line"
assert_eq "$(parse_old "${compact}")" "" "old sed misses compact sdk line"
assert_eq "$(parse_old "${spaced}")" "" "old sed misses space before colon"

# shellcheck disable=SC1091
source "${root}/autoroot.sh"

assert_eq "$(parse_sdkversion "${pretty}")" "3.4.0" "new parser pretty"
assert_eq "$(parse_sdkversion "${compact}")" "3.4.0" "new parser compact"
assert_eq "$(parse_sdkversion "${spaced}")" "3.4.0" "new parser spaced colon"
assert_eq "$(parse_sdkversion "")" "" "new parser empty"

tempdir="${work}/tmp"
logfile="${work}/autoroot.log"
mkdir -p -- "${tempdir}"
: >"${logfile}"

# Closed pipe: the raw client returns an empty body.
raw="$(true | "${bin}/luna-send-pub" -w 1000 -n 1 -q sdkVersion -f \
    'luna://com.webos.service.tv.systemproperty/getSystemInfo' '{"keys":["sdkVersion"]}' || true)"
assert_eq "${raw}" "" "closed-pipe client body is empty"

# Same closed-pipe stdin, but luna_pub holds its own writer. Body must survive.
held="$(true | {
    luna_pub -w 1000 -n 1 -q 'sdkVersion' -f \
        'luna://com.webos.service.tv.systemproperty/getSystemInfo' '{"keys":["sdkVersion"]}'
    printf '%s' "${luna_pub_stdout}"
})"
assert_eq "${held}" "$(printf '{\n    "sdkVersion": "3.4.0"\n}')" "held stdin keeps pretty body"

python3 - "${LUNA_MOCK_LOG}" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
closed = [row for row in rows if row["hup"]]
held = [row for row in rows if not row["hup"] and any("getSystemInfo" in arg for arg in row["argv"])]
if not closed:
    raise SystemExit("expected a hung-up client call")
if not held:
    raise SystemExit("expected a held-stdin getSystemInfo call")
print("hup-vs-held: ok")
PY

# /dev/null is not a hangup. The helper still returns the body.
luna_pub -w 1000 -n 1 -q 'sdkVersion' -f \
    'luna://com.webos.service.tv.systemproperty/getSystemInfo' '{"keys":["sdkVersion"]}' </dev/null
assert_eq "$(parse_sdkversion "${luna_pub_stdout}")" "3.4.0" "devnull stdin still parses"
if ! refuse_silent_luna; then
    fail "non-empty body must not abort"
fi

# Compact body, stderr kept apart from stdout, non-zero status still kept.
export LUNA_MOCK_FORMAT=compact
export LUNA_MOCK_STDERR='LUNASERVICE note only'
export LUNA_MOCK_STATUS=3
: >"${LUNA_MOCK_LOG}"
luna_pub -w 1000 -n 1 -q 'sdkVersion' -f \
    'luna://com.webos.service.tv.systemproperty/getSystemInfo' '{"keys":["sdkVersion"]}'
assert_eq "$(parse_sdkversion "${luna_pub_stdout}")" "3.4.0" "compact status capture parses"
assert_eq "${luna_pub_status}" "3" "client exit status is kept"
case "${luna_pub_stdout}" in
    *LUNASERVICE*) fail "stderr leaked into stdout" ;;
esac
case "${luna_pub_err}" in
    *'LUNASERVICE note only'*) ;;
    *) fail "stderr was not captured" ;;
esac
unset LUNA_MOCK_FORMAT LUNA_MOCK_STDERR LUNA_MOCK_STATUS

# Empty body aborts before any addMvpd argument is sent.
export LUNA_MOCK_EMPTY=1
: >"${LUNA_MOCK_LOG}"
: >"${logfile}"
luna_pub -w 1000 -n 1 -q 'sdkVersion' -f \
    'luna://com.webos.service.tv.systemproperty/getSystemInfo' '{"keys":["sdkVersion"]}'
if refuse_silent_luna; then
    fail "empty body must abort"
fi
python3 - "${LUNA_MOCK_LOG}" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
for row in rows:
    if any(arg == "luna://com.webos.service.mvpd/vendor/addMvpd" for arg in row["argv"]):
        raise SystemExit("empty getSystemInfo must not call addMvpd")
print("no-addMvpd: ok")
PY
if ! grep -q 'not calling /addMvpd' "${logfile}"; then
    fail "abort was not logged"
fi
unset LUNA_MOCK_EMPTY

# Payload bytes that reach the client stay literal. The mock does not run them.
: >"${LUNA_MOCK_LOG}"
payload_uninterp='$XDG_DIR-abc123'
mvpd_payload="$(printf '{"appId":"`sh %s`"}' "${payload_uninterp}")"
luna_pub -n 1 'luna://com.webos.service.mvpd/vendor/addMvpd' "${mvpd_payload}"
python3 - "${LUNA_MOCK_LOG}" "${mvpd_payload}" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
found = [row for row in rows if any(arg == "luna://com.webos.service.mvpd/vendor/addMvpd" for arg in row["argv"])]
if len(found) != 1:
    raise SystemExit(f"expected one addMvpd call, got {len(found)}")
argv = found[0]["argv"]
if argv != ["-n", "1", "luna://com.webos.service.mvpd/vendor/addMvpd", sys.argv[2]]:
    raise SystemExit("payload argv changed: " + json.dumps(argv))
if found[0]["hup"]:
    raise SystemExit("payload call saw hangup")
print("payload-bytes: ok")
PY
if ! check_luna_return "${luna_pub_stdout}"; then
    fail "compact returnValue must pass the existing check"
fi

pretty_ok='{
    "returnValue": true
}'
if check_luna_return "${pretty_ok}"; then
    fail "pretty returnValue unexpectedly matched; do not switch addMvpd to -f"
fi

# Static guards: same payload expression, remove uses its own body, no new shell.
if ! grep -q 'printf '"'"'{"appId":"`sh %s`"}'"'"'' "${root}/autoroot.sh"; then
    fail "upstream payload format missing"
fi
if ! grep -q 'check_luna_return "${remove_mvpd_out}"' "${root}/autoroot.sh"; then
    fail "removeMvpd still ignores its own response"
fi
if ! grep -q 'check_luna_return "${add_mvpd_out}"' "${root}/autoroot.sh"; then
    fail "addMvpd no longer checks its own response"
fi
telnet_count="$(grep -c 'telnetd' "${root}/autoroot.sh")"
assert_eq "${telnet_count}" "1" "telnetd occurrences"
if grep -q '1337' "${root}/autoroot.sh"; then
    fail "unexpected telnet port"
fi

python3 - "${root}/autoroot.sh" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
def line_no(fragment):
    for i, line in enumerate(text, 1):
        if fragment in line:
            return i
    raise SystemExit("missing " + fragment)
order = [
    "luna_pub -w 1000 -n 1 -q 'sdkVersion'",
    "if ! refuse_silent_luna; then",
    "downloading...",
    "luna://com.webos.service.mvpd/vendor/addMvpd",
]
numbers = [line_no(fragment) for fragment in order]
if numbers != sorted(numbers):
    raise SystemExit("call order changed: " + str(list(zip(order, numbers))))
print("call-order: ok")
PY

left="$(ps -u "$(id -u)" -o args= | grep 'sleep 3600' | grep -v grep || true)"
if [ -n "${left}" ]; then
    fail "stdin holder still running: ${left}"
fi

printf 'all offline luna-capture tests passed\n'
