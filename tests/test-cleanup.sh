#!/usr/bin/env bash
# Exercise destructive cleanup boundaries without contacting Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/caduceus-cleanup-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TEST_ROOT/mock-bin" "$TEST_ROOT/repo/bin"
cp "$ROOT/bin/cleanup" "$TEST_ROOT/repo/bin/cleanup"
cp "$ROOT/docker-compose.yml" "$TEST_ROOT/repo/docker-compose.yml"

cat > "$TEST_ROOT/mock-bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$1" >> "$MOCK_LOG"
printf '\t%s' "${@:2}" >> "$MOCK_LOG"
printf '\n' >> "$MOCK_LOG"
args=" $* "
project="$MOCK_PROJECT"
[ ! -f "$MOCK_PROJECT_FILE" ] || project="$(cat "$MOCK_PROJECT_FILE")"
if [ "$1" = compose ]; then
  previous=""
  for arg in "$@"; do
    case "$previous" in -p|--project-name) project="$arg" ;; esac
    previous="$arg"
  done
  case "$args" in
    *' version '*) printf 'Docker Compose version v2.39.0\n' ;;
    *' --environment '*) printf 'HERMES_DATA_DIR=%s\n' "$MOCK_DATA_DIR" ;;
    *' config '*)
      printf '%s\n' "$project" > "$MOCK_PROJECT_FILE"
      if [ "${MOCK_QUOTE_PROJECT:-0}" = 1 ]; then
        printf 'name: "%s"\nservices: {}\n' "$project"
      else
        printf 'name: %s\nservices: {}\n' "$project"
      fi
      ;;
    *) printf 'Unexpected compose command: %s\n' "$*" >&2; exit 90 ;;
  esac
  exit 0
fi
case "$args" in
  ' info '*|' version '*) exit 0 ;;
  ' ps '*|' container ls '*|' volume ls '*|' network ls '*)
    scoped=false
    for arg in "$@"; do
      [ "$arg" != "label=com.docker.compose.project=$project" ] || scoped=true
    done
    "$scoped" || { printf 'Inventory was not project scoped: %s\n' "$*" >&2; exit 91; }
    [ "${MOCK_EMPTY:-0}" != 1 ] || exit 0
    case "$args" in
      ' ps '*|' container ls '*) printf 'container-current\ncontainer-orphan\n' ;;
      ' volume ls '*) printf '%s_database\n%s_retired-data\n' "$project" "$project" ;;
      ' network ls '*) printf 'network-project\n' ;;
    esac
    ;;
  ' image ls '*|' images '*)
    [ "${MOCK_EMPTY:-0}" != 1 ] || exit 0
    case "$args" in
      # Other instances share the Docker host, so built tags must be matched
      # exactly for this project, never by a caduceus-* style pattern.
      *'reference='*'*'*) printf 'Image reference is a pattern: %s\n' "$*" >&2; exit 95 ;;
      *" reference=$project-hermes "*" reference=$project-obsidian-sync "*)
        printf '%s-hermes:local\n%s-hermes:previous\n%s-obsidian-sync:local\n' \
          "$project" "$project" "$project" ;;
      *'reference='*) printf 'Image references were not project scoped: %s\n' "$*" >&2; exit 96 ;;
      *"label=com.docker.compose.project=$project"*) printf 'sha256:dangling-project\n' ;;
      *) printf 'Images were not scoped: %s\n' "$*" >&2; exit 92 ;;
    esac
    ;;
  ' stop '*|' rm '*|' container stop '*|' container rm '*|' volume rm '*|' network rm '*|' image rm '*)
    case "$args" in
      *' --force '*|*' -f '*) printf 'Forced removal is not allowed: %s\n' "$*" >&2; exit 94 ;;
    esac
    printf '%s\n' "$*" >> "$MOCK_MUTATIONS"
    ;;
  *) printf 'Unexpected docker command: %s\n' "$*" >&2; exit 93 ;;
esac
MOCK
chmod +x "$TEST_ROOT/mock-bin/docker"
export PATH="$TEST_ROOT/mock-bin:$PATH"
export MOCK_LOG="$TEST_ROOT/docker.log"
export MOCK_MUTATIONS="$TEST_ROOT/mutations.log"
export MOCK_PROJECT_FILE="$TEST_ROOT/project"
export MOCK_PROJECT=caduceus
export MOCK_DATA_DIR=./data/hermes
export MOCK_EMPTY=0
export MOCK_QUOTE_PROJECT=0
SCRIPT="$TEST_ROOT/repo/bin/cleanup"
OUTPUT="$TEST_ROOT/output"

clear_logs() {
  : > "$MOCK_LOG"
  : > "$MOCK_MUTATIONS"
  printf '%s\n' "$MOCK_PROJECT" > "$MOCK_PROJECT_FILE"
}
run() { bash "$SCRIPT" "$@" </dev/null > "$OUTPUT" 2>&1; }
expect_failure() {
  if run "$@"; then fail "expected failure: $*"; fi
}
expect_no_mutations() {
  [ ! -s "$MOCK_MUTATIONS" ] || fail "unexpected Docker mutation: $(cat "$MOCK_MUTATIONS")"
}
contains() {
  awk -v text="$2" 'index($0, text) {found=1} END {exit !found}' "$1"
}

clear_logs
run --help
expect_no_mutations
[ ! -s "$MOCK_LOG" ] || fail 'help should not require Docker'
printf 'ok: help works without Docker\n'

for option in --unknown --project-name; do
  clear_logs
  expect_failure "$option"
  expect_no_mutations
done
printf 'ok: invalid flags fail before mutation\n'

mkdir -p "$TEST_ROOT/repo/data/hermes"
printf 'keep me\n' > "$TEST_ROOT/repo/data/hermes/session"
clear_logs
run --dry-run --reset-data
expect_no_mutations
[ -f "$TEST_ROOT/repo/data/hermes/session" ] || fail 'dry run removed host state'
contains "$OUTPUT" caduceus || fail 'dry run does not identify the project'
printf 'ok: dry run preserves Docker and host state\n'

clear_logs
expect_failure
expect_no_mutations
printf 'ok: missing noninteractive confirmation cancels\n'

clear_logs
run --yes
[ -s "$MOCK_MUTATIONS" ] || fail 'cleanup did not remove Docker resources'
contains "$MOCK_MUTATIONS" container-current || fail 'current container was missed'
contains "$MOCK_MUTATIONS" container-orphan || fail 'orphan container was missed'
contains "$MOCK_MUTATIONS" caduceus_retired-data || fail 'retired volume was missed'
contains "$MOCK_MUTATIONS" network-project || fail 'project network was missed'
contains "$MOCK_MUTATIONS" caduceus-hermes:local || fail 'built image was missed'
contains "$MOCK_MUTATIONS" caduceus-obsidian-sync:local || fail 'built sync image was missed'
contains "$MOCK_MUTATIONS" sha256:dangling-project || fail 'dangling project image was missed'
[ -f "$TEST_ROOT/repo/data/hermes/session" ] || fail 'default cleanup removed host state'
printf 'ok: cleanup includes orphan resources and preserves host state by default\n'

# The path must remain one literal argument, even when it contains shell syntax.
export MOCK_DATA_DIR='./data/hermes with spaces; $(touch SHOULD_NOT_EXIST)'
mkdir -p "$TEST_ROOT/repo/$MOCK_DATA_DIR"
printf 'remove me\n' > "$TEST_ROOT/repo/$MOCK_DATA_DIR/session"
clear_logs
run --yes --reset-data
[ ! -e "$TEST_ROOT/repo/$MOCK_DATA_DIR" ] || fail 'custom host directory was not removed'
[ ! -e "$TEST_ROOT/repo/SHOULD_NOT_EXIST" ] || fail 'custom path was executed as shell code'
[ -f "$TEST_ROOT/repo/data/hermes/session" ] || fail 'custom reset touched the default data directory'
printf 'ok: custom data paths are handled literally\n'

for dangerous in / "$TEST_ROOT/repo" "$TEST_ROOT/repo/.."; do
  export MOCK_DATA_DIR="$dangerous"
  clear_logs
  expect_failure --yes --reset-data
  expect_no_mutations
done
printf 'ok: dangerous host paths fail before Docker mutation\n'

mkdir -p "$TEST_ROOT/outside-data"
printf 'keep me\n' > "$TEST_ROOT/outside-data/session"
ln -s "$TEST_ROOT/outside-data" "$TEST_ROOT/repo/data/symlink"
for symlink in ./data/symlink ./data/symlink/; do
  export MOCK_DATA_DIR="$symlink"
  clear_logs
  expect_failure --yes --reset-data
  expect_no_mutations
  [ -f "$TEST_ROOT/outside-data/session" ] || fail 'symlink target was removed'
done
printf 'ok: host data symlinks are refused with or without trailing slashes\n'

mkdir -p "$TEST_ROOT/repo/config"
printf 'keep me\n' > "$TEST_ROOT/repo/config/keep"
git init --quiet "$TEST_ROOT/repo"
git -C "$TEST_ROOT/repo" add config/keep
export MOCK_DATA_DIR=./config
clear_logs
expect_failure --yes --reset-data
expect_no_mutations
[ -f "$TEST_ROOT/repo/config/keep" ] || fail 'tracked installation config was removed'
printf 'ok: tracked installation directories are refused\n'

# An external bind mount is valid and must not be passed to git ls-files.
export MOCK_DATA_DIR="$TEST_ROOT/outside-data"
clear_logs
run --yes --reset-data
[ ! -e "$TEST_ROOT/outside-data" ] || fail 'external host directory was not removed'
if contains "$OUTPUT" 'fatal:'; then fail 'external data triggered a Git error'; fi
printf 'ok: external host directories reset without Git errors\n'

# Linked worktrees use a .git file rather than a directory.
git -C "$TEST_ROOT/repo" init --quiet --separate-git-dir="$TEST_ROOT/repo-git"
[ -f "$TEST_ROOT/repo/.git" ] || fail 'worktree-style fixture has no .git file'
export MOCK_DATA_DIR=./config
clear_logs
expect_failure --yes --reset-data
expect_no_mutations
[ -f "$TEST_ROOT/repo/config/keep" ] || fail 'tracked worktree config was removed'
printf 'ok: tracked directories remain protected when .git is a file\n'

export MOCK_DATA_DIR=./data/hermes
clear_logs
run --dry-run --project-name caduceus-test
expect_no_mutations
contains "$MOCK_LOG" label=com.docker.compose.project=caduceus-test || fail 'project override was not used'
contains "$MOCK_LOG" reference=caduceus-test-hermes || fail 'project override did not scope image tags'
printf 'ok: project override scopes resource queries\n'

# A second instance on the same host must not take the first one's images.
export MOCK_PROJECT=dana
clear_logs
run --yes
contains "$MOCK_MUTATIONS" dana-hermes:local || fail 'instance image was missed'
contains "$MOCK_MUTATIONS" dana-obsidian-sync:local || fail 'instance sync image was missed'
if contains "$MOCK_MUTATIONS" caduceus-; then fail 'cleanup removed another instance'"'"'s images'; fi
printf 'ok: cleanup of one instance leaves other instances'"'"' images alone\n'
export MOCK_PROJECT=caduceus

export MOCK_PROJECT=123
export MOCK_QUOTE_PROJECT=1
clear_logs
run --dry-run
expect_no_mutations
contains "$MOCK_LOG" label=com.docker.compose.project=123 || fail 'quoted numeric project was not resolved'
printf 'ok: quoted numeric Compose project names are accepted\n'
export MOCK_PROJECT=caduceus
export MOCK_QUOTE_PROJECT=0

export MOCK_EMPTY=1
clear_logs
run --yes
expect_no_mutations
printf 'ok: already-clean installations are harmless\n'

printf 'All cleanup checks passed.\n'
