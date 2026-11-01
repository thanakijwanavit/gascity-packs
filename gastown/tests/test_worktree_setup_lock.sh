#!/usr/bin/env bash
# worktree-setup.sh serializes worktree creation per repository. Pool
# sessions of one rig start together; without the lock, concurrent
# `git worktree add -b <branch> origin/<default>` runs collide on
# .git/config ("could not lock config file .git/config: File exists") and
# leave sessions with no worktree (G1, 1 Nov 2026).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/gastown/assets/scripts/worktree-setup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

git_c() {
    git -c user.email=a@a.com -c user.name=a "$@"
}

new_upstream_and_rig() {
    local base="$1"
    git_c init -q --bare -b main "$base/upstream.git"
    git_c init -q -b main "$base/seed"
    (cd "$base/seed" && git_c commit -q --allow-empty -m init \
        && git_c remote add origin "$base/upstream.git" \
        && git_c push -q origin main)
    git_c clone -q "$base/upstream.git" "$base/rig"
}

lock_path() {
    printf '%s/gc-worktree-setup.lock' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
}

# Many agents of one rig at once: every worktree is created, every branch
# tracks origin/main, and no lock is left behind.
test_concurrent_setups_all_succeed() {
    local base="$1" rig="$1/rig" n=8 i pids=() rc=0
    for i in $(seq 1 "$n"); do
        sh "$SCRIPT" "$rig" "$base/wt-par-$i" "agent$i" >"$base/par-$i.log" 2>&1 &
        pids+=("$!")
    done
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || { rc=1; echo "--- setup $((i + 1)) failed:" >&2; cat "$base/par-$((i + 1)).log" >&2; }
    done
    [ "$rc" = 0 ] || fail "concurrent worktree-setup runs failed"
    for i in $(seq 1 "$n"); do
        [ -f "$base/wt-par-$i/.git" ] || fail "worktree $i missing"
        [ "$(git_c -C "$base/wt-par-$i" rev-parse --abbrev-ref '@{u}')" = "origin/main" ] ||
            fail "worktree $i branch does not track origin/main"
    done
    [ ! -e "$(lock_path "$rig")" ] || fail "repo lock left behind after concurrent setups"
}

# A lock whose holder died (SIGKILL: no trap ran) is replaced, not waited on.
test_stale_lock_from_dead_holder_is_replaced() {
    local base="$1" rig="$1/rig" lock dead
    lock=$(lock_path "$rig")
    sh -c 'exit 0' &
    dead=$!
    wait "$dead"
    mkdir "$lock"
    echo "$dead" >"$lock/pid"
    GC_WORKTREE_SETUP_LOCK_WAIT=5 sh "$SCRIPT" "$rig" "$base/wt-stale" stale 2>"$base/stale.log" ||
        { cat "$base/stale.log" >&2; fail "setup should take over a stale lock"; }
    grep -q 'removed stale repo lock' "$base/stale.log" || fail "stale lock takeover was not reported"
    [ -f "$base/wt-stale/.git" ] || fail "worktree missing after stale-lock takeover"
    [ ! -e "$lock" ] || fail "repo lock left behind after stale-lock takeover"
}

# A live holder is waited on, and the wait is bounded with a clear error;
# the holder's lock is not touched.
test_live_lock_times_out_cleanly() {
    local base="$1" rig="$1/rig" lock holder
    lock=$(lock_path "$rig")
    sleep 30 &
    holder=$!
    mkdir "$lock"
    echo "$holder" >"$lock/pid"
    if GC_WORKTREE_SETUP_LOCK_WAIT=2 sh "$SCRIPT" "$rig" "$base/wt-live" live 2>"$base/live.log"; then
        kill "$holder" 2>/dev/null || true
        fail "setup should fail while a live holder keeps the lock"
    fi
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    grep -q 'timed out after 2s waiting for repo lock' "$base/live.log" ||
        { cat "$base/live.log" >&2; fail "timeout message missing"; }
    [ "$(cat "$lock/pid")" = "$holder" ] || fail "waiter must not remove a live holder's lock"
    [ ! -e "$base/wt-live/.git" ] || fail "no worktree should be created without the lock"
    rm -rf "$lock"
}

# --sync on an existing worktree writes shared git state too (fetch,
# checkout -b with tracking), so it waits for the repo lock; with the lock
# free it syncs and releases it.
test_sync_existing_worktree_uses_lock() {
    local base="$1" rig="$1/rig" lock holder
    lock=$(lock_path "$rig")
    sh "$SCRIPT" "$rig" "$base/wt-sync" syncer >/dev/null 2>&1 || fail "initial setup for sync test failed"
    sleep 30 &
    holder=$!
    mkdir "$lock"
    echo "$holder" >"$lock/pid"
    if GC_WORKTREE_SETUP_LOCK_WAIT=2 sh "$SCRIPT" "$rig" "$base/wt-sync" syncer --sync 2>"$base/sync-held.log"; then
        kill "$holder" 2>/dev/null || true
        fail "--sync should wait for a live holder's lock"
    fi
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    grep -q 'timed out after 2s waiting for repo lock' "$base/sync-held.log" ||
        { cat "$base/sync-held.log" >&2; fail "--sync did not wait on the repo lock"; }
    rm -rf "$lock"
    sh "$SCRIPT" "$rig" "$base/wt-sync" syncer --sync 2>"$base/sync.log" ||
        { cat "$base/sync.log" >&2; fail "--sync with a free lock failed"; }
    [ ! -e "$lock" ] || fail "repo lock left behind after --sync"
}

# A failed worktree add exits non-zero and still releases the lock.
test_failed_add_releases_lock() {
    local base="$1" rig="$1/rig" lock
    lock=$(lock_path "$rig")
    # Target path is a regular file: git worktree add refuses it.
    : >"$base/wt-file"
    if sh "$SCRIPT" "$rig" "$base/wt-file" filetarget 2>"$base/fileadd.log"; then
        fail "worktree add onto a regular file should fail"
    fi
    grep -q 'failed to create worktree' "$base/fileadd.log" ||
        { cat "$base/fileadd.log" >&2; fail "expected worktree add failure"; }
    [ ! -e "$lock" ] || fail "repo lock left behind after failed worktree add"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
new_upstream_and_rig "$tmp"

test_concurrent_setups_all_succeed "$tmp"
test_stale_lock_from_dead_holder_is_replaced "$tmp"
test_live_lock_times_out_cleanly "$tmp"
test_sync_existing_worktree_uses_lock "$tmp"
test_failed_add_releases_lock "$tmp"

echo "worktree-setup lock tests passed"
