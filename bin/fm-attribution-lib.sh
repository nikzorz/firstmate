#!/usr/bin/env bash
# Single owner of what counts as an agent attribution trailer in this repo.
#
# AGENTS.md forbids naming an agent as a commit co-author, but every supported
# harness is told the opposite by its own vendor: claude injects a
# "Co-Authored-By: <model> <noreply@anthropic.com>" instruction plus a
# "Claude-Session: <url>" conversation link, and codex injects
# "Co-authored-by: Codex <noreply@openai.com>" from an account-side workspace
# policy that explicitly overrides repository rules. Recognition is therefore by
# the agent's email address rather than by its display name, which varies with
# the model in use, and human co-authors are never matched.
#
# fm_attribution_strip filters a commit message on stdin and writes it to stdout
# with those lines removed. Blank runs are collapsed only where a removal
# created them, and a trailing separator left introducing an emptied co-author
# block is dropped, so an untouched message passes through byte-for-byte.

FM_ATTRIBUTION_AGENT_EMAILS='noreply@anthropic.com noreply@openai.com'

fm_attribution_strip() {
  awk -v emails="$FM_ATTRIBUTION_AGENT_EMAILS" '
    function is_agent_coauthor(line,   start, stop, addr) {
      if (tolower(line) !~ /^co-authored-by:[ \t]/) return 0
      start = index(line, "<")
      stop = index(line, ">")
      if (start == 0 || stop <= start) return 0
      addr = tolower(substr(line, start + 1, stop - start - 1))
      return (addr in agent)
    }
    # A session link is a trace of the conversation that produced the code, which
    # this repo keeps out of durable history for the same reason as a co-author.
    function is_session_trace(line) {
      return tolower(line) ~ /^claude-session:[ \t]/
    }
    BEGIN {
      count = split(emails, list, " ")
      for (i = 1; i <= count; i++) agent[tolower(list[i])] = 1
    }
    {
      if (is_agent_coauthor($0) || is_session_trace($0)) {
        removed = 1
        any_removed = 1
        next
      }
      if ($0 ~ /^[ \t]*$/) { blanks++; next }
      if (kept > 0) {
        gap = blanks
        if (removed && gap > 1) gap = 1
        for (i = 0; i < gap; i++) out[++kept] = ""
      }
      blanks = 0
      removed = 0
      out[++kept] = $0
    }
    END {
      if (any_removed && kept > 0 && out[kept] ~ /^-{3,}$/) {
        kept--
        while (kept > 0 && out[kept] == "") kept--
      }
      for (i = 1; i <= kept; i++) print out[i]
    }
  '
}
