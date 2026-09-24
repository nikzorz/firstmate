#!/usr/bin/env bash
# tests/secondmate-helpers.sh - shared fixtures and mocks for the secondmate
# suites (fm-secondmate-lifecycle-e2e and fm-secondmate-safety).
#
# These mocks encode secondmate-lifecycle behavior (fake tmux that logs window
# ops, fake treehouse that leases/returns homes, fake no-mistakes that records
# init/doctor), so they live here rather than in the generic tests/lib.sh. The
# generic git/identity/meta primitives come from lib.sh, which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# These suites drive teardown and spawn paths that reach a backend CLI, and an
# unstubbed herdr call there starts a live server on the host that outlives the
# suite. Every herdr reached without a test's own fake therefore hits a refusing
# shim, and the suite fails at exit if that shim was called or if a herdr process
# carrying this suite's token is still running; such a process is reaped before
# the failure is reported. The token is what attributes a process to this suite,
# so a herdr the operator or a sibling suite runs is never touched.
FM_TEST_HERDR_GUARD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-guard.XXXXXX")
FM_TEST_HERDR_GUARD_TOKEN=$(basename "$FM_TEST_HERDR_GUARD_DIR")
export FM_TEST_HERDR_GUARD_TOKEN
mkdir -p "$FM_TEST_HERDR_GUARD_DIR/bin"
cat > "$FM_TEST_HERDR_GUARD_DIR/bin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$FM_TEST_HERDR_GUARD_DIR/calls.log'
echo "refused: unstubbed herdr call from a secondmate suite: herdr \$*" >&2
exit 97
SH
chmod +x "$FM_TEST_HERDR_GUARD_DIR/bin/herdr"
PATH="$FM_TEST_HERDR_GUARD_DIR/bin:$PATH"

# Echo the pid of every running herdr process that inherited this suite's token.
fm_test_herdr_guard_leaked_pids() {
  local pid
  [ -d /proc ] || return 0
  command -v pgrep >/dev/null 2>&1 || return 0
  for pid in $(pgrep -x herdr 2>/dev/null); do
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
      | grep -qxF "FM_TEST_HERDR_GUARD_TOKEN=$FM_TEST_HERDR_GUARD_TOKEN" \
      && printf '%s\n' "$pid"
  done
  return 0
}

fm_test_herdr_guard_exit() {
  local status=$? leaked pid
  # A test may leave errexit on, and a failing check here must still report.
  set +e
  leaked=$(fm_test_herdr_guard_leaked_pids)
  if [ -n "$leaked" ]; then
    for pid in $leaked; do
      printf 'not ok - a herdr process started by this suite outlived it: %s\n' \
        "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" >&2
      kill "$pid" 2>/dev/null
    done
    status=1
  fi
  if [ -s "$FM_TEST_HERDR_GUARD_DIR/calls.log" ]; then
    printf 'not ok - unstubbed herdr calls reached the real CLI path:\n' >&2
    sed 's/^/  herdr /' "$FM_TEST_HERDR_GUARD_DIR/calls.log" >&2
    status=1
  fi
  rm -rf "$FM_TEST_HERDR_GUARD_DIR"
  fm_test_cleanup
  exit "$status"
}
trap fm_test_herdr_guard_exit EXIT

# A fake tmux (window ops are logged to FM_FAKE_TMUX_LOG, list-windows returns
# FM_FAKE_TMUX_WINDOW, capture-pane echoes FM_FAKE_TMUX_CAPTURE) plus a fake
# treehouse (durable lease of FM_FAKE_TREEHOUSE_HOME, recording the lease holder
# to FM_FAKE_TREEHOUSE_LEASE_FILE; `return` removes the target and lease unless
# FM_FAKE_TREEHOUSE_RETURN_FAIL is set, or FM_FAKE_TREEHOUSE_RETURN_KEEPS_DIR
# models the production slot return that keeps the pooled directory).
# FM_FAKE_TMUX_KILL_WINDOW_LANDS_META names a child meta the fake writes while it
# kills a window, which is how a test lands one between a teardown's in-flight
# refusal and its child record sweep. A fake herdr rides along because a child
# recorded on the herdr backend is closed by pane, and the real CLI's close path
# starts a live server for the recorded session first; its calls are logged as
# `herdr <args>` to FM_FAKE_TMUX_LOG, a pane it has closed reads as gone, and every
# other pane reads as present. Echoes the fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  # A real, positively identified empty agent composer. A blank capture is
  # deliberately unknown under the fleet-wide strict blank-row posture.
  printf '❯\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    if [ "${1:-}" = kill-window ] && [ -n "${FM_FAKE_TMUX_KILL_WINDOW_LANDS_META:-}" ]; then
      printf 'window=firstmate:fm-late\nkind=ship\nmode=no-mistakes\n' \
        > "$FM_FAKE_TMUX_KILL_WINDOW_LANDS_META"
    fi
    exit 0
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        case "$arg" in
          ". '"*"'")
            staged=${arg#". '"}
            staged=${staged%"'"}
            [ ! -f "$staged" ] || printf 'staged-launch %s\n' "$(cat "$staged")" >> "$FM_FAKE_TMUX_LOG"
            ;;
        esac
      fi
      prev=$arg
    done
    exit 0
    ;;
  list-windows)
    session=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -t ]; then session=$arg; break; fi
      prev=$arg
    done
    while IFS= read -r recorded; do
      [ -n "$recorded" ] || continue
      if [ -z "$session" ]; then
        printf '%s\n' "$recorded"
        continue
      fi
      case "$recorded" in
        "$session":*) printf '%s\n' "${recorded#*:}" ;;
        *:*) ;;
        *) printf '%s\n' "$recorded" ;;
      esac
    done <<EOF
${FM_FAKE_TMUX_WINDOW:-}
EOF
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  get)
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
      [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    fi
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    if [ -n "${FM_FAKE_TREEHOUSE_RETURN_KEEPS_DIR:-}" ]; then
      # The production slot return: the lease is released and tracked content is
      # reset, but the pooled directory stays for the next holder, so gitignored
      # state/ survives the return.
      exit 0
    fi
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf 'herdr %s\\n' "\$*" >> "\${FM_FAKE_TMUX_LOG:-/dev/null}"
session=
prev=
for arg in "\$@"; do
  [ "\$prev" = --session ] && session=\$arg
  prev=\$arg
done
case "\${1:-} \${2:-}" in
  'status --json') printf '{"server":{"running":true}}\\n' ;;
  'session list')
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\\n' "\$session" '$dir/herdr.sock'
    ;;
  'pane close') printf '%s\\n' "\${3:-}" >> '$dir/herdr-closed' ;;
  'pane get')
    if grep -qxF -- "\${3:-}" '$dir/herdr-closed' 2>/dev/null; then
      printf '%s\\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\\n' "\${3:-}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/treehouse"
  chmod +x "$fakebin/herdr"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that records each "<pwd>\t<verb>" call to
# FM_FAKE_NO_MISTAKES_LOG and fails for the project named FM_FAKE_NO_MISTAKES_FAIL_PROJECT.
make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal firstmate home (AGENTS.md + bin/).
mark_firstmate_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
}

# A firstmate home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests).
make_firstmate_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/fm-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/fm-guard.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# Scaffold a filled secondmate charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_secondmate_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" >/dev/null
}

# Make a directory look like a genuine seeded secondmate home (for handoff tests).
seed_secondmate_home_marker() {
  local home=$1 id=$2
  mark_firstmate_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
