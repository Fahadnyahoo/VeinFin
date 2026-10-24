#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT="$REPO_DIR/scripts/host/prepare-debian.sh"
TEST_TMP=$(mktemp -d /tmp/veinfin-host-tests.XXXXXX)
MOCK_BIN="$TEST_TMP/bin"
PASS_COUNT=0

cleanup() {
  find "$TEST_TMP" -depth -delete
}
trap cleanup EXIT HUP INT TERM

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_failure() {
  test_name=$1
  shift
  if "$@" >"$TEST_TMP/failure.log" 2>&1; then
    fail "$test_name unexpectedly succeeded"
  fi
  pass "$test_name rejected"
}

mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/dpkg" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --print-architecture ]; then printf '%s\n' "${MOCK_ARCH:-amd64}"; exit 0; fi
exit 1
EOF
cat >"$MOCK_BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
package=${*: -1}
if [ -n "${MOCK_INSTALLED_PACKAGE:-}" ] && [ "$package" = "$MOCK_INSTALLED_PACKAGE" ]; then
  printf 'install ok installed|1.0-test\n'
  exit 0
fi
exit 1
EOF
cat >"$MOCK_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$MOCK_BIN/getent" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
cat >"$MOCK_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -nG ]; then printf 'users\n'; exit 0; fi
exec /usr/bin/id "$@"
EOF
chmod 0755 "$MOCK_BIN"/*

write_os_release() {
  target=$1
  os_id=$2
  version=$3
  codename=$4
  mkdir -p "$(dirname "$target")"
  printf 'ID=%s\nVERSION_ID=%s\nVERSION_CODENAME=%s\n' "$os_id" "$version" "$codename" >"$target"
}

bash -n "$SCRIPT"
pass "shell syntax"

"$SCRIPT" --help >"$TEST_TMP/help.log"
grep -q -- '--check' "$TEST_TMP/help.log" || fail "help omitted --check"
grep -q -- '--apply' "$TEST_TMP/help.log" || fail "help omitted --apply"
pass "help output"

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  expect_failure "non-root apply" "$SCRIPT" --apply
else
  printf 'SKIP: non-root apply rejection (test runner is root)\n'
fi

clean_root="$TEST_TMP/clean-root"
write_os_release "$clean_root/etc/os-release" debian 13 trixie
before=$(find "$clean_root" -type f -exec cksum {} \; | sort)
PATH="$MOCK_BIN:$PATH" VEINFIN_HOST_ROOT="$clean_root" "$SCRIPT" --check >"$TEST_TMP/check.log"
after=$(find "$clean_root" -type f -exec cksum {} \; | sort)
[ "$before" = "$after" ] || fail "--check mutated its test root"
pass "check immutability"

bad_os="$TEST_TMP/bad-os"
write_os_release "$bad_os/etc/os-release" ubuntu 24.04 noble
expect_failure "unsupported OS" env PATH="$MOCK_BIN:$PATH" VEINFIN_HOST_ROOT="$bad_os" "$SCRIPT" --check

bad_arch="$TEST_TMP/bad-arch"
write_os_release "$bad_arch/etc/os-release" debian 13 trixie
expect_failure "unsupported architecture" env PATH="$MOCK_BIN:$PATH" MOCK_ARCH=arm64 VEINFIN_HOST_ROOT="$bad_arch" "$SCRIPT" --check

conflict_root="$TEST_TMP/conflict-root"
write_os_release "$conflict_root/etc/os-release" debian 13 trixie
mkdir -p "$conflict_root/var/lib/docker"
expect_failure "existing runtime data" env PATH="$MOCK_BIN:$PATH" VEINFIN_HOST_ROOT="$conflict_root" "$SCRIPT" --check

package_root="$TEST_TMP/package-root"
write_os_release "$package_root/etc/os-release" debian 13 trixie
expect_failure "conflicting runtime package" env PATH="$MOCK_BIN:$PATH" MOCK_INSTALLED_PACKAGE=docker.io VEINFIN_HOST_ROOT="$package_root" "$SCRIPT" --check

source_conflict_root="$TEST_TMP/source-conflict-root"
write_os_release "$source_conflict_root/etc/os-release" debian 13 trixie
mkdir -p "$source_conflict_root/etc/apt/sources.list.d"
printf 'deb https://example.invalid/debian stable main\n' >"$source_conflict_root/etc/apt/sources.list.d/docker.sources"
expect_failure "conflicting Docker source" env PATH="$MOCK_BIN:$PATH" VEINFIN_HOST_ROOT="$source_conflict_root" "$SCRIPT" --check

if rg -n '(apt-get|apt)[[:space:]]+(remove|purge)|get\.docker\.com|curl[^\n]*\|[^\n]*(sh|bash)|2375|2376|usermod|gpasswd|groupmod|docker[[:space:]]+group' "$SCRIPT" >"$TEST_TMP/static.log"; then
  grep -Eq '(apt-get|apt)[[:space:]]+(remove|purge)|curl[^|]*\|[^|]*(sh|bash)|usermod|gpasswd|groupmod' "$TEST_TMP/static.log" && fail "prohibited destructive/convenience/group command found"
fi
grep -q 'docker run' "$SCRIPT" && fail "script runs a container"
grep -q 'docker pull' "$SCRIPT" && fail "script pulls an image"
grep -q 'tcp://' "$SCRIPT" && fail "script configures Docker TCP access"
grep -Eq '(apt-get|apt)[[:space:]]+(upgrade|full-upgrade)|docker[[:space:]]+swarm[[:space:]]+init|(^|[[:space:]])reboot([[:space:]]|$)' "$SCRIPT" && fail "script performs an upgrade, configures Swarm, or reboots"
pass "prohibited operations absent"

atomic_root="$TEST_TMP/atomic-root"
mkdir -p "$atomic_root"
printf 'expected\n' >"$TEST_TMP/expected"
printf 'conflict\n' >"$TEST_TMP/conflict"
(
  VEINFIN_PREPARE_LIBRARY_ONLY=1 . "$SCRIPT"
  write_atomic_if_absent_or_equal "$atomic_root/docker.sources" "$TEST_TMP/expected" 0644
  first=$(cksum "$atomic_root/docker.sources")
  write_atomic_if_absent_or_equal "$atomic_root/docker.sources" "$TEST_TMP/expected" 0644
  [ "$first" = "$(cksum "$atomic_root/docker.sources")" ] || exit 1
  if (write_atomic_if_absent_or_equal "$atomic_root/docker.sources" "$TEST_TMP/conflict" 0644) >/dev/null 2>&1; then
    exit 1
  fi
) || fail "repository configuration was not idempotent or overwrote a conflict"
pass "idempotent repository configuration"

printf 'Host preparation tests passed: %s checks.\n' "$PASS_COUNT"
