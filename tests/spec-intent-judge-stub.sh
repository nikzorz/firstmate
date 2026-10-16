#!/usr/bin/env bash
# Stand-in for the model bin/fm-spec-intent-check.sh asks, named through
# FM_SPEC_INTENT_CHECK_CLAUDE_BIN. tests/lib.sh and tests/herdr-test-safety.sh
# arm it for every suite so a ship spawn never reaches a real model; with no knobs set it answers ok for
# every numbered bullet it is sent.
#   FM_STUB_JUDGE_FLAG     ERE; a bullet whose text matches is answered flag.
#   FM_STUB_JUDGE_ANSWER   file whose contents are the whole answer instead.
#   FM_STUB_JUDGE_EXIT     exit status to return after answering.
#   FM_STUB_JUDGE_LOG      file that receives the arguments and the message.
set -u
message=$(cat)
if [ -n "${FM_STUB_JUDGE_LOG:-}" ]; then
  { printf 'args:'; printf ' [%s]' "$@"; printf '\n%s\n' "$message"; } >> "$FM_STUB_JUDGE_LOG"
fi
if [ -n "${FM_STUB_JUDGE_ANSWER:-}" ]; then
  cat "$FM_STUB_JUDGE_ANSWER"
else
  printf '%s\n' "$message" | awk -v flag="${FM_STUB_JUDGE_FLAG:-}" '
    match($0, /^[0-9]+\. /) {
      n = substr($0, 1, RLENGTH - 2)
      text = substr($0, RLENGTH + 1)
      if (flag != "" && text ~ flag) print n " flag: matched the stub pattern"
      else print n " ok"
    }
  '
fi
exit "${FM_STUB_JUDGE_EXIT:-0}"
