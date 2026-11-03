#!/usr/bin/env bash
# Exclusive directory claims that stay exclusive where mkdir(1) is not atomic.
#
# A claim or lock directory used to be won by whichever caller's `mkdir` exited
# zero. uutils coreutils mkdir (0.10.0, shipped as /usr/bin/mkdir on
# ubuntu-26.04) checks for the path and then creates it, so two racers can both
# exit zero for one directory and both believe they hold it.
#
# fm_claim_dir keeps the directory as the visible claim, so every reader that
# tests `-d` and every file a holder writes inside it are unchanged, but it
# settles ownership with a token file created by bash's own noclobber open
# (O_CREAT|O_EXCL in the shell, no external binary): of every caller whose
# mkdir reported success, exactly one creates the token. A directory that
# already existed still refuses at mkdir, as before.
#
# The token lives inside the claim directory, so a holder releases with
# fm_claim_dir_release, and any code that empties a claim directory before
# rmdir removes FM_CLAIM_TOKEN with the rest of its records.

FM_CLAIM_TOKEN=.fm-claim

# fm_claim_dir <path>: 0 only for the single caller that now owns <path>.
# Runs under the caller's umask, so wrap it as `(umask 077; fm_claim_dir ...)`
# for a private claim. Silent on refusal, like `mkdir ... 2>/dev/null`.
fm_claim_dir() {
  mkdir -- "$1" 2>/dev/null || return 1
  (set -C; : > "$1/$FM_CLAIM_TOKEN") 2>/dev/null
}

# fm_claim_dir_release <path>: remove the token, then rmdir <path>; fails like
# rmdir when other entries remain.
fm_claim_dir_release() {
  rm -f -- "$1/$FM_CLAIM_TOKEN" 2>/dev/null
  rmdir -- "$1" 2>/dev/null
}
