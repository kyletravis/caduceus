#!/usr/bin/env bash
#
# Back up and restore one Caduceus instance.
#
# One instance = one checkout (~/caduceus, ~/caduceus-dana, ...) = one Compose
# project. Everything is resolved through `docker compose config` in that
# checkout, the same way bin/cleanup does it, so it works both before and after
# the multi-instance layout (fixed container_name or not).
#
# An archive holds:
#   .env                         secrets and instance settings
#   HERMES_DATA_DIR              config, sessions, uploads, skills
#   OBSIDIAN_VAULT_DIR           unless --no-vault
#   config/                      bind-mounted SearXNG settings and starter config
#   every named volume labeled com.docker.compose.project=<project>
#   vendor/<repo>.commit/.patch  local edits in vendor/ checkouts (bin/setup
#                                reclones without them)
#   images.tar.gz                with --with-images: every image the project uses
#   manifest + SHA256SUMS
#
# The stack is stopped for the snapshot (SQLite in Matrix, Mnemosyne,
# obsidian-sync) and the services that were running are started again.
#
# Works with macOS /bin/bash 3.2 and Linux. Needs docker + compose v2.
set -euo pipefail

FORMAT_VERSION=1
HELPER_IMAGE="${CADUCEUS_BACKUP_IMAGE:-alpine:3.20}"
DEST="${CADUCEUS_BACKUP_DIR:-}"   # empty: <checkout>/backups (gitignored)
LABEL_PROJECT=com.docker.compose.project
LABEL_VOLUME=com.docker.compose.volume

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  caduceus-backup backup  [-C DIR] [-o DEST] [-p NAME] [--no-vault]
                          [--exclude-volume SHORT]... [--hot] [--keep N]
                          [--with-images]
  caduceus-backup restore ARCHIVE [-C DIR] [-p NAME] [--keep-env] [--no-vault]
                          [--with-config] [--with-images] [--extract-vendor DIR]
                          [--exclude-volume SHORT]... [--start] [--yes]
  caduceus-backup verify  ARCHIVE
  caduceus-backup list    [-C DIR] [-o DEST]

  -C DIR                 Instance checkout (default: parent of this script if it
                         lives in a checkout's bin/, else the current directory).
  -o DEST                Backup directory (default: $CADUCEUS_BACKUP_DIR or
                         <checkout>/backups, which is gitignored).
  -p, --project-name N   Override the Compose project name (as bin/cleanup).
  --no-vault             Skip OBSIDIAN_VAULT_DIR (Obsidian Sync holds a copy).
  --exclude-volume SHORT Skip a volume by its compose name, e.g.
                         hermes-dependencies (hermes-init reinstalls it).
  --hot                  Don't stop the stack. SQLite stores may be inconsistent.
  --keep N               After a backup, keep only the newest N for this project.
  --with-images          Backup: also docker save every image the project uses
                         (several GB; taken after the stack is running again).
                         Restore: docker load them back, restoring :local tags.
  --extract-vendor DIR   Restore: copy the archived vendor/ commits and patches
                         to DIR so they can be re-applied by hand.
  --keep-env             Restore: keep the target checkout's .env instead of the
                         archived one (use when restoring into another instance).
  --with-config          Restore: also overwrite config/ from the archive.
  --start                Restore: run `docker compose up -d` afterwards.
  --yes                  Restore: skip the typed confirmation.

Examples:
  caduceus-backup backup -C ~/caduceus --keep 14
  caduceus-backup backup -C ~/caduceus --with-images        # before risky changes
  caduceus-backup backup -C ~/caduceus-dana -o /Volumes/NAS/caduceus
  caduceus-backup restore ~/caduceus/backups/caduceus-20261101T140000Z.caduceus.tar -C ~/caduceus --with-images --start

Restore moves an existing data or vault directory aside to
<dir>.pre-restore-<timestamp> instead of deleting it, and replaces the contents
of each restored volume. Volumes are mapped by short name, so an archive of
project "caduceus" restores into project "dana" as dana_<volume>.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
sha256_check() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c --quiet "$@"; else shasum -a 256 -c --quiet "$@"; fi
}
oneline() { printf '%s' "$1" | tr '\n' ' ' | sed 's/ *$//'; }
utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
strip_quotes() { sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }

default_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [ -f "$here/../docker-compose.yml" ]; then (cd "$here/.." && pwd -P); else pwd -P; fi
}

preflight_docker() {
  command -v docker >/dev/null || fail 'docker is required'
  docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required'
  docker info >/dev/null 2>&1 || fail 'cannot reach Docker; start Docker Desktop and check the context'
}

# Sets ROOT and the compose array.
init_checkout() {
  [ -n "$ROOT" ] || ROOT="$(default_root)"
  [ -d "$ROOT" ] || fail "checkout not found: $ROOT"
  ROOT="$(cd "$ROOT" && pwd -P)"
  [ -f "$ROOT/docker-compose.yml" ] || fail "no docker-compose.yml in $ROOT (pass -C DIR)"
  compose=(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml")
  # Quiet per-container progress lines where this Compose supports it.
  if docker compose --progress quiet version >/dev/null 2>&1; then compose+=(--progress quiet); fi
  if [ -n "$PROJECT_OVERRIDE" ]; then compose+=(--project-name "$PROJECT_OVERRIDE"); fi
}

resolve_project() {
  PROJECT="$("${compose[@]}" config 2>/dev/null | sed -n 's/^name: //p' | head -1 | tr -d "\"'")"
  [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "could not resolve the Compose project name in $ROOT"
}

# Value of a variable as Compose sees it (.env plus shell overrides), without
# sourcing .env as code. Falls back to reading .env directly.
ENV_FILE=''
compose_env() {
  local v f="${ENV_FILE:-$ROOT/.env}"
  v="$("${compose[@]}" config --environment 2>/dev/null | sed -n "s/^$1=//p" | head -1 || true)"
  if [ -z "$v" ] && [ -f "$f" ]; then
    v="$(grep -E "^$1=" "$f" | head -1 | cut -d= -f2- || true)"
  fi
  printf '%s' "$v" | strip_quotes
}

abs_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    \~/*) p="$HOME/${p#\~/}" ;;
    *) p="$ROOT/${p#./}" ;;
  esac
  while [ "$p" != / ] && [[ "$p" == */ ]]; do p="${p%/}"; done
  printf '%s' "$p"
}

resolve_paths() {
  local d v
  d="$(compose_env HERMES_DATA_DIR)"; DATA_DIR="$(abs_path "${d:-./data/hermes}")"
  v="$(compose_env OBSIDIAN_VAULT_DIR)"; VAULT_DIR="$(abs_path "${v:-./data/obsidian}")"
}

resolve_paths_from() { ENV_FILE="$1"; resolve_paths; ENV_FILE=''; }

# Refuse to move or replace anything that would take the checkout, home or /.
guard_target_dir() {
  local d="$1"
  [ "$d" != / ] || fail 'refusing to replace /'
  [ ! -L "$d" ] || fail "refusing to replace a symlink: $d"
  case "$ROOT/" in "$d/"*) fail "refusing to replace the checkout or an ancestor: $d" ;; esac
  case "${HOME:-/}/" in "$d/"*) fail "refusing to replace the home directory or an ancestor: $d" ;; esac
  case "$d/" in "$ROOT/.git/"*|"$ROOT/vendor/"*|"$ROOT/config/"*|"$ROOT/bin/"*)
    fail "refusing to replace installation files: $d" ;;
  esac
}

# Named volumes of the project, as "fullname shortname" lines: everything
# labeled with the project, plus unlabeled <project>_* volumes (created by hand
# or by an old restore). A volume labeled for another project is never taken.
project_volumes() {
  local v short owner
  {
    docker volume ls -q --filter "label=$LABEL_PROJECT=$PROJECT"
    docker volume ls -q | grep -E "^${PROJECT}_" || true
  } | sort -u | while IFS= read -r v; do
    [ -n "$v" ] || continue
    owner="$(docker volume inspect -f "{{ index .Labels \"$LABEL_PROJECT\" }}" "$v" 2>/dev/null || true)"
    case "$owner" in ''|'<no value>'|"$PROJECT") ;; *) continue ;; esac
    short="$(docker volume inspect -f "{{ index .Labels \"$LABEL_VOLUME\" }}" "$v" 2>/dev/null || true)"
    case "$short" in ''|'<no value>') short="${v#"${PROJECT}"_}" ;; esac
    printf '%s %s\n' "$v" "$short"
  done
}

is_excluded() {
  local x
  for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do [ "$x" = "$1" ] && return 0; done
  return 1
}

ensure_helper_image() {
  docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || docker pull -q "$HELPER_IMAGE" >/dev/null
}

# Stream a volume out through a throwaway container: no host bind mount, so
# Docker Desktop file sharing and host permissions don't matter.
volume_to_file() {
  docker run --rm --network none -v "$1:/v:ro" "$HELPER_IMAGE" \
    tar -C /v -czf - . > "$2"
}
file_to_volume() {
  docker run --rm -i --network none -v "$1:/v" "$HELPER_IMAGE" \
    sh -c 'find /v -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -C /v -xzpf -' < "$2"
}

# COPYFILE_DISABLE keeps macOS tar from adding ._ AppleDouble files.
dir_to_file() { COPYFILE_DISABLE=1 tar -C "$1" -czf "$2" .; }
file_to_dir() { mkdir -p "$1" && tar -C "$1" -xzpf "$2"; }

running_services() { "${compose[@]}" ps --status running --services 2>/dev/null || true; }

# Default the backup directory to <checkout>/backups (gitignored), then make it
# absolute. Call after init_checkout.
resolve_dest() {
  [ -n "$DEST" ] || DEST="$ROOT/backups"
  case "$DEST" in /*) ;; \~/*) DEST="$HOME/${DEST#\~/}" ;; *) DEST="$PWD/$DEST" ;; esac
}

# Fail if $1 lies inside $2: the archive would end up containing older archives.
guard_not_inside() {
  case "$1/" in "$2/"*) fail "backup directory $1 is inside $2; pick another with -o" ;; esac
}

# Image references the project runs, one per line.
project_images() { "${compose[@]}" config --images 2>/dev/null | sort -u; }

# Record each vendor/ checkout's commit plus any local edits, so a rebuild from
# bin/setup's fresh clone can be brought back to what the images were built from.
capture_vendor() {  # capture_vendor OUTDIR -> prints captured repo names
  local out="$1" d name untracked
  [ -d "$ROOT/vendor" ] || return 0
  for d in "$ROOT"/vendor/*; do
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    name="$(basename "$d")"
    mkdir -p "$out"
    git -C "$d" rev-parse HEAD > "$out/$name.commit"
    git -C "$d" diff HEAD --binary > "$out/$name.patch"
    untracked="$(git -C "$d" ls-files --others --exclude-standard)"
    if [ -n "$untracked" ]; then
      printf '%s\n' "$untracked" | (cd "$d" && COPYFILE_DISABLE=1 tar -czf "$out/$name-untracked.tgz" -T -)
    fi
    printf '%s\n' "$name"
  done
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
STOPPED_SERVICES=''
STAGE=''
restart_stopped() {
  if [ -n "$STOPPED_SERVICES" ]; then
    say "==> Starting $(oneline "$STOPPED_SERVICES") again"
    # shellcheck disable=SC2086 # service names are simple tokens
    "${compose[@]}" start $STOPPED_SERVICES >/dev/null || warn 'restart failed; run docker compose up -d'
    STOPPED_SERVICES=''
  fi
}
backup_cleanup() {
  local rc=$?
  restart_stopped
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  if [ "$rc" -ne 0 ]; then warn 'backup failed; no archive was written'; fi
  exit "$rc"
}

cmd_backup() {
  local no_vault=false hot=false keep='' with_images=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) ROOT="${2:?-C needs a directory}"; shift ;;
      -o) DEST="${2:?-o needs a directory}"; shift ;;
      -p|--project-name) PROJECT_OVERRIDE="${2:?--project-name needs a name}"; shift ;;
      --no-vault) no_vault=true ;;
      --exclude-volume) EXCLUDES+=("${2:?--exclude-volume needs a name}"); shift ;;
      --hot) hot=true ;;
      --with-images) with_images=true ;;
      --keep) keep="${2:?--keep needs a number}"; [[ "$keep" =~ ^[1-9][0-9]*$ ]] || fail '--keep needs a positive number'; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown argument: $1 (see --help)" ;;
    esac
    shift
  done

  preflight_docker
  init_checkout
  [ -f "$ROOT/.env" ] || fail "no .env in $ROOT"
  resolve_project
  resolve_paths
  ensure_helper_image

  local images=''
  if "$with_images"; then
    images="$(project_images)"
    [ -n "$images" ] || fail 'could not list the project images (docker compose config --images)'
    while IFS= read -r line; do
      docker image inspect "$line" >/dev/null 2>&1 || fail "image not present locally: $line (build or pull it first)"
    done <<< "$images"
  fi

  resolve_dest
  umask 077
  mkdir -p "$DEST"
  DEST="$(cd "$DEST" && pwd -P)"
  guard_not_inside "$DEST" "$DATA_DIR"
  if ! "$no_vault"; then guard_not_inside "$DEST" "$VAULT_DIR"; fi
  local ts name final vols line full short included='' vendor_repos=''
  ts="$(utc_stamp)"
  name="${PROJECT}-${ts}.caduceus.tar"
  final="$DEST/$name"
  [ ! -e "$final" ] || fail "archive already exists: $final"
  STAGE="$(mktemp -d "$DEST/.${name}.partial.XXXXXX")"
  trap backup_cleanup EXIT
  mkdir -p "$STAGE/volumes"

  vols="$(project_volumes)"
  say "Caduceus backup"
  say "  checkout  $ROOT"
  say "  project   $PROJECT"
  say "  data      $DATA_DIR"
  if "$no_vault"; then say '  vault     (skipped)'; else say "  vault     $VAULT_DIR"; fi
  if "$with_images"; then say "  images    $(oneline "$images")"; fi
  say "  archive   $final"

  if ! "$hot"; then
    STOPPED_SERVICES="$(running_services)"
    if [ -n "$STOPPED_SERVICES" ]; then
      say "==> Stopping $(oneline "$STOPPED_SERVICES") for a consistent snapshot"
      "${compose[@]}" stop >/dev/null
    fi
  else
    warn '--hot: containers keep running; SQLite stores may be captured mid-write'
  fi

  say '==> .env and config'
  cp "$ROOT/.env" "$STAGE/dot-env"
  if [ -d "$ROOT/config" ]; then dir_to_file "$ROOT/config" "$STAGE/config.tgz"; fi
  cp "$ROOT/docker-compose.yml" "$STAGE/docker-compose.yml"
  if [ -f "$ROOT/versions.env" ]; then cp "$ROOT/versions.env" "$STAGE/versions.env"; fi

  if [ -d "$DATA_DIR" ]; then
    say "==> Hermes data ($DATA_DIR)"
    dir_to_file "$DATA_DIR" "$STAGE/hermes-data.tgz"
  else
    warn "HERMES_DATA_DIR not found, skipping: $DATA_DIR"
  fi
  if ! "$no_vault"; then
    if [ -d "$VAULT_DIR" ]; then
      say "==> Obsidian vault ($VAULT_DIR)"
      dir_to_file "$VAULT_DIR" "$STAGE/vault.tgz"
    else
      warn "OBSIDIAN_VAULT_DIR not found, skipping: $VAULT_DIR"
    fi
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    full="${line%% *}"; short="${line#* }"
    if is_excluded "$short"; then say "==> volume $short (excluded)"; continue; fi
    say "==> volume $short ($full)"
    volume_to_file "$full" "$STAGE/volumes/$short.tgz"
    included="$included $short"
  done <<< "$vols"

  # Data is captured; bring the instance back before the slower bookkeeping.
  restart_stopped

  say '==> vendor/ commits and local edits'
  vendor_repos="$(capture_vendor "$STAGE/vendor")"

  if "$with_images"; then
    say '==> images (docker save, this takes a while)'
    # shellcheck disable=SC2086 # image references contain no whitespace
    docker save $images | gzip > "$STAGE/images.tar.gz"
  fi

  {
    printf 'format_version=%s\n' "$FORMAT_VERSION"
    printf 'project=%s\n' "$PROJECT"
    printf 'created_utc=%s\n' "$ts"
    printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'checkout=%s\n' "$ROOT"
    printf 'git_commit=%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'data_dir=%s\n' "$DATA_DIR"
    if "$no_vault"; then printf 'vault_dir=\n'; else printf 'vault_dir=%s\n' "$VAULT_DIR"; fi
    printf 'volumes=%s\n' "${included# }"
    printf 'vendor=%s\n' "$(oneline "$vendor_repos")"
    printf 'images=%s\n' "$(oneline "$images")"
    printf 'hot=%s\n' "$hot"
    printf 'helper_image=%s\n' "$HELPER_IMAGE"
  } > "$STAGE/manifest"

  local sums
  sums="$(cd "$STAGE" && find . -type f | LC_ALL=C sort | sed 's|^\./||' |
          while IFS= read -r f; do sha256 "$f"; done)"
  printf '%s\n' "$sums" > "$STAGE/SHA256SUMS"

  COPYFILE_DISABLE=1 tar -C "$STAGE" -cf "$final.partial" .
  mv "$final.partial" "$final"
  rm -rf "$STAGE"; STAGE=''
  trap - EXIT

  say "==> Wrote $final ($(du -h "$final" | cut -f1))"
  if [ -n "$keep" ]; then prune "$keep"; fi
}

archives_for() {  # archives_for PROJECT -> oldest first
  local f
  for f in "$DEST/$1"-[0-9]*T*Z.caduceus.tar; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

prune() {
  local keep="$1" all count drop f
  all="$(archives_for "$PROJECT")"
  count="$(printf '%s\n' "$all" | grep -c . || true)"
  [ "$count" -gt "$keep" ] || return 0
  drop=$((count - keep))
  printf '%s\n' "$all" | head -n "$drop" | while IFS= read -r f; do
    say "==> pruned $(basename "$f")"
    rm -f -- "$f"
  done
}

# ---------------------------------------------------------------------------
# verify / restore
# ---------------------------------------------------------------------------
WORK=''
work_cleanup() { if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi; }

open_archive() {
  local archive="$1"
  [ -f "$archive" ] || fail "archive not found: $archive"
  WORK="$(mktemp -d "$(dirname "$archive")/.caduceus-restore.XXXXXX")"
  trap work_cleanup EXIT
  tar -C "$WORK" -xf "$archive"
  [ -f "$WORK/manifest" ] && [ -f "$WORK/SHA256SUMS" ] || fail 'not a caduceus-backup archive (no manifest)'
  (cd "$WORK" && sha256_check SHA256SUMS) || fail 'checksum mismatch: archive is damaged'
  [ "$(mget format_version)" = "$FORMAT_VERSION" ] || fail "unsupported archive format: $(mget format_version)"
}
mget() { sed -n "s/^$1=//p" "$WORK/manifest" | head -1; }

cmd_verify() {
  [ "$#" -eq 1 ] || fail 'usage: caduceus-backup verify ARCHIVE'
  open_archive "$1"
  say "OK  $1"
  sed 's/^/  /' "$WORK/manifest"
}

cmd_list() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) ROOT="${2:?-C needs a directory}"; shift ;;
      -o) DEST="${2:?-o needs a directory}"; shift ;;
      *) fail "unknown argument: $1" ;;
    esac
    shift
  done
  if [ -z "$DEST" ]; then init_checkout; fi
  resolve_dest
  [ -d "$DEST" ] || fail "no backup directory: $DEST"
  local f found=false m created imgs
  for f in "$DEST"/*.caduceus.tar; do
    [ -f "$f" ] || continue
    found=true
    m="$(tar -xOf "$f" ./manifest 2>/dev/null || true)"
    created="$(printf '%s\n' "$m" | sed -n 's/^created_utc=//p')"
    imgs="$(printf '%s\n' "$m" | sed -n 's/^images=//p')"
    printf '%8s  %-16s  %-9s  %s\n' "$(du -h "$f" | cut -f1)" "${created:-?}" \
      "$([ -n "$imgs" ] && echo '+images' || echo 'data')" "$f"
  done
  "$found" || say "no archives in $DEST"
}

move_aside() {  # move_aside DIR STAMP
  local d="$1"
  [ -e "$d" ] || return 0
  guard_target_dir "$d"
  if [ -d "$d" ] && [ -z "$(ls -A "$d")" ]; then return 0; fi
  mv -- "$d" "$d.pre-restore-$2"
  say "  moved existing $d -> $d.pre-restore-$2"
}

cmd_restore() {
  local archive='' keep_env=false no_vault=false with_config=false start=false yes=false
  local with_images=false vendor_out=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) ROOT="${2:?-C needs a directory}"; shift ;;
      -p|--project-name) PROJECT_OVERRIDE="${2:?--project-name needs a name}"; shift ;;
      --keep-env) keep_env=true ;;
      --no-vault) no_vault=true ;;
      --with-config) with_config=true ;;
      --with-images) with_images=true ;;
      --extract-vendor) vendor_out="${2:?--extract-vendor needs a directory}"; shift ;;
      --exclude-volume) EXCLUDES+=("${2:?--exclude-volume needs a name}"); shift ;;
      --start) start=true ;;
      --yes) yes=true ;;
      -h|--help) usage; exit 0 ;;
      -*) fail "unknown argument: $1 (see --help)" ;;
      *) [ -z "$archive" ] || fail 'only one archive'; archive="$1" ;;
    esac
    shift
  done
  [ -n "$archive" ] || fail 'usage: caduceus-backup restore ARCHIVE [options]'

  preflight_docker
  init_checkout
  archive="$(cd "$(dirname "$archive")" && pwd -P)/$(basename "$archive")"
  open_archive "$archive"
  if "$with_images" && [ ! -f "$WORK/images.tar.gz" ]; then
    fail '--with-images, but this archive has no images (it was taken without --with-images)'
  fi
  ensure_helper_image

  local src_project src_vols ts short full
  src_project="$(mget project)"
  src_vols="$(mget volumes)"
  ts="$(utc_stamp)"

  # Stop the current stack under its current name before anything changes.
  local old_project=''
  old_project="$("${compose[@]}" config 2>/dev/null | sed -n 's/^name: //p' | head -1 | tr -d "\"'" || true)"

  # Plan against the archived .env (unless --keep-env) without touching the
  # checkout yet: it decides the target project name and data paths.
  local base_compose
  base_compose=("${compose[@]}")
  if "$keep_env"; then
    [ -f "$ROOT/.env" ] || fail "--keep-env, but $ROOT has no .env"
  else
    compose+=(--env-file "$WORK/dot-env")
  fi
  resolve_project
  if "$keep_env"; then resolve_paths; else resolve_paths_from "$WORK/dot-env"; fi

  say "Caduceus restore"
  say "  archive   $archive"
  say "  from      project $src_project, $(mget created_utc), $(mget host)"
  say "  into      $ROOT (project $PROJECT)"
  if "$keep_env"; then say '  .env      kept'; else say '  .env      restored from archive'; fi
  if [ -f "$WORK/hermes-data.tgz" ]; then say "  data      $DATA_DIR"; fi
  if [ -f "$WORK/vault.tgz" ] && ! "$no_vault"; then say "  vault     $VAULT_DIR"; fi
  if "$with_config" && [ -f "$WORK/config.tgz" ]; then say "  config    $ROOT/config"; fi
  if "$with_images"; then say "  images    $(mget images)"; fi
  for short in $src_vols; do
    if is_excluded "$short"; then say "  volume    $short (excluded)"; else say "  volume    ${PROJECT}_$short"; fi
  done
  if [ "$src_project" != "$PROJECT" ]; then
    warn "restoring project $src_project into $PROJECT. If $src_project still runs with the same MATRIX_* bot account, two logins break E2EE; give this instance its own bot or stop the other one."
  fi

  if ! "$yes"; then
    [ -t 0 ] || fail 'confirmation needs a terminal; use --yes'
    say ''
    say 'This replaces the listed data and volume contents.'
    printf 'Type "%s" to continue: ' "$PROJECT"
    local answer=''
    IFS= read -r answer || true
    [ "$answer" = "$PROJECT" ] || fail 'cancelled; nothing changed'
  fi

  if ! "$keep_env"; then
    if [ -f "$ROOT/.env" ] && ! cmp -s "$WORK/dot-env" "$ROOT/.env"; then
      cp -p "$ROOT/.env" "$ROOT/.env.pre-restore-$ts"
      say "  saved previous .env -> .env.pre-restore-$ts"
    fi
    cp "$WORK/dot-env" "$ROOT/.env"
    chmod 600 "$ROOT/.env"
    compose=("${base_compose[@]}")
  fi

  say '==> Stopping the stack'
  if [ -n "$old_project" ] && [ "$old_project" != "$PROJECT" ]; then
    docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" \
      --project-name "$old_project" stop >/dev/null 2>&1 || true
  fi
  "${compose[@]}" stop >/dev/null 2>&1 || true

  if [ -f "$WORK/hermes-data.tgz" ]; then
    say "==> Hermes data -> $DATA_DIR"
    move_aside "$DATA_DIR" "$ts"
    file_to_dir "$DATA_DIR" "$WORK/hermes-data.tgz"
  fi
  if [ -f "$WORK/vault.tgz" ] && ! "$no_vault"; then
    say "==> Obsidian vault -> $VAULT_DIR"
    move_aside "$VAULT_DIR" "$ts"
    file_to_dir "$VAULT_DIR" "$WORK/vault.tgz"
  fi
  if "$with_config" && [ -f "$WORK/config.tgz" ]; then
    say "==> config/"
    tar -C "$ROOT/config" -xzpf "$WORK/config.tgz"
  fi

  for short in $src_vols; do
    is_excluded "$short" && continue
    full="${PROJECT}_$short"
    say "==> volume $short -> $full"
    if ! docker volume inspect "$full" >/dev/null 2>&1; then
      docker volume create --label "$LABEL_PROJECT=$PROJECT" --label "$LABEL_VOLUME=$short" "$full" >/dev/null
    fi
    file_to_volume "$full" "$WORK/volumes/$short.tgz"
  done

  if "$with_images"; then
    say '==> images (docker load)'
    gunzip -c "$WORK/images.tar.gz" | docker load
  fi

  local repo vendor_repos
  vendor_repos="$(mget vendor)"
  if [ -n "$vendor_repos" ] && [ -n "$vendor_out" ]; then
    mkdir -p "$vendor_out"
    cp -p "$WORK"/vendor/* "$vendor_out"/
    vendor_out="$(cd "$vendor_out" && pwd -P)"
    say "==> vendor/ commits and patches -> $vendor_out"
  fi

  if "$start"; then
    say '==> docker compose up -d'
    "${compose[@]}" up -d
  fi
  say ''
  say 'Restore complete. Next:'
  "$start" || say '  docker compose up -d'
  say '  bin/status && bin/check-integrations'
  for repo in $vendor_repos; do
    if [ -n "$vendor_out" ]; then
      say "  vendor/$repo was at $(cat "$vendor_out/$repo.commit"); before rebuilding it, run:"
      say "    git -C vendor/$repo checkout $(cat "$vendor_out/$repo.commit") && git -C vendor/$repo apply $vendor_out/$repo.patch"
      [ ! -f "$vendor_out/$repo-untracked.tgz" ] || say "    tar -C vendor/$repo -xzf $vendor_out/$repo-untracked.tgz"
    else
      say "  vendor/$repo commit and local edits are in the archive; rerun with --extract-vendor DIR to get them"
    fi
  done
  say "  then delete any *.pre-restore-$ts directories you no longer need"
}

# ---------------------------------------------------------------------------
ROOT=''
PROJECT=''
PROJECT_OVERRIDE=''
DATA_DIR=''
VAULT_DIR=''
EXCLUDES=()
compose=()

[ "$#" -gt 0 ] || { usage; exit 1; }
cmd="$1"; shift
case "$cmd" in
  backup)  cmd_backup "$@" ;;
  restore) cmd_restore "$@" ;;
  verify)  cmd_verify "$@" ;;
  list)    cmd_list "$@" ;;
  -h|--help|help) usage ;;
  *) fail "unknown command: $cmd (see --help)" ;;
esac
