#!/usr/bin/env bash
# Single owner of what counts as an agent attribution trailer in this repo.
#
# AGENTS.md forbids naming an agent as a commit co-author, but the two harnesses
# whose trailers have been measured here are told the opposite by their own
# vendor: claude injects a "Co-Authored-By: <model> <noreply@anthropic.com>"
# instruction plus a "Claude-Session: <url>" conversation link, and codex
# injects "Co-authored-by: Codex <noreply@openai.com>" from an account-side
# workspace policy that explicitly overrides repository rules. Recognition is
# therefore by the agent's email address rather than by its display name, which
# varies with the model in use, and human co-authors are never matched.
#
# fm_attribution_strip filters a commit message on stdin and writes it to stdout
# with those lines removed. Blank runs are collapsed only where a removal
# created them, and a trailing separator is dropped only when the co-author
# block it introduced is the thing the strip emptied, so an untouched message
# passes through byte-for-byte.

# Claude and codex are the whole of the measured set. The repo's other verified
# harnesses - opencode, pi, grok, and kimi - are not installed on this machine,
# so whether they inject a trailer, and under which address, is unknown rather
# than known to be nothing. Covering one means first measuring the trailer that
# runtime actually emits and then adding the address it uses; never add a
# guessed address, because a wrong one silently strips a human co-author.
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
      # "removed" survives to END only when every line after the last kept one
      # was stripped, which is exactly a separator whose block the strip emptied.
      if (removed && kept > 0 && out[kept] ~ /^-{3,}$/) {
        kept--
        while (kept > 0 && out[kept] == "") kept--
      }
      for (i = 1; i <= kept; i++) print out[i]
    }
  '
}
