#!/bin/bash
# When the backup's own verification FAILS, does anybody actually hear about it?
#
# WHY THIS EXISTS (2026-09-25, card ffedf99d). backup.sh verifies its archive and
# exits 6 when items are missing. That failure goes to stdout, which launchd sends
# to logs/backup.log, which nobody opens -- so the script also puts the failure on
# the agent message queue. Measured that day, the call did neither thing it looked
# like it was doing:
#
#   1. It was addressed to `halpali halpali`. There is no such agent on this
#      install (/api/agents: gembaecho, leanarchivist, leanchief, leandev,
#      leanlibrarian, leanpublisher, leanscout, leanwriter). The message went
#      nowhere in particular.
#   2. It ended in `>/dev/null 2>&1 || true`. scripts/agent-msg.sh exists BECAUSE
#      an inter-agent send fails silently (HTTP 200 with no id, 401, a dead
#      dashboard) and it reports that with exit 1 -- and this call threw the
#      result away. A failure alert that fails quietly is the same silence the
#      verification was built to break.
#
# So the assertions here are about DELIVERY, not about the wording: who it is
# addressed to, and what the script says when the send does not succeed. Every
# run works on a throwaway fake install with a STUB agent-msg.sh, so no real
# message is ever sent and no real dashboard is touched.
set -uo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

INSTALL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_BACKUP_SH="${SRC_BACKUP_SH:-$INSTALL_DIR/scripts/backup.sh}"
BASE="$(mktemp -d -t backup-alert.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

echo "backup-failure-alert"
echo "===================="

# One fake $HOME for every run. It has to be a REAL one (skills, scheduled-tasks,
# settings.json), otherwise the control run in section (5) fails verification for
# reasons that have nothing to do with the alert, and proves nothing.
H="$BASE/home"
mkdir -p "$H/.claude/hooks" "$H/.claude/skills/s" "$H/.claude/scheduled-tasks"
printf 'import sys\n'           > "$H/.claude/hooks/a_hook.py"
printf '{"hooks":{"Stop":[]}}'  > "$H/.claude/settings.json"
printf '{"mcpServers":{}}'      > "$H/.claude.json"
printf 'skill\n'                > "$H/.claude/skills/s/SKILL.md"
printf '{"cron":"0 8 * * *"}\n' > "$H/.claude/scheduled-tasks/t.json"

# mkinstall <dir> <main-agent-id> <stub-exit> -- a fake install whose backup ALWAYS
# fails verification, with a stub agent-msg.sh that records its argv and exits as told.
# The failure is forced the same way the sibling suite does it: a staging copy that
# silently does nothing, which leaves every manifest entry unmatched.
mkinstall() {
  local d="$1" mid="$2" stubrc="$3"
  mkdir -p "$d/scripts" "$d/store" "$d/backups"
  sed 's|    cp -pR "${base}/${rel}" "${STAGE}/${group}/${parent}/"|    true|' \
    "$SRC_BACKUP_SH" > "$d/scripts/backup.sh"
  printf 'db\n' > "$d/store/claudeclaw.db"
  printf 'MAIN_AGENT_ID=%s\n' "$mid" > "$d/.env"
  cat > "$d/scripts/agent-msg.sh" <<STUB
#!/usr/bin/env bash
# stub: record the call, then exit as the test asked
printf '%s\n' "\$*" > "$d/alert-argv.txt"
echo "stub agent-msg.sh spoke"
exit $stubrc
STUB
  chmod +x "$d/scripts/agent-msg.sh"
}

# --- (1) the recipient ------------------------------------------------------
echo
echo "(1) the alert goes to MAIN_AGENT_ID, not to a made-up agent"
A="$BASE/ok"
mkinstall "$A" "chief-of-this-install" 0
AOUT="$BASE/ok.out"
HOME="$H" BACKUP_DIR="$A/backups" bash "$A/scripts/backup.sh" > "$AOUT" 2>&1
ARC=$?
if [ "$ARC" -eq 6 ]; then pass "a backup that carries nothing still exits 6"
else fail "expected exit 6, got $ARC"; sed 's/^/        /' "$AOUT"; fi

if [ -f "$A/alert-argv.txt" ]; then
  ARGV="$(cat "$A/alert-argv.txt")"
  pass "the alert was actually invoked"
  # from and to are the first two words; both must be the resolved MAIN_AGENT_ID.
  if [ "$(echo "$ARGV" | awk '{print $1}')" = "chief-of-this-install" ] \
  && [ "$(echo "$ARGV" | awk '{print $2}')" = "chief-of-this-install" ]; then
    pass "addressed from/to the MAIN_AGENT_ID resolved out of .env"
  else
    fail "wrong recipient: $(echo "$ARGV" | awk '{print $1, $2}')"
  fi
  case "$ARGV" in
    *halpali*) fail "the hardcoded 'halpali' recipient is back" ;;
    *)         pass "no hardcoded agent name in the call" ;;
  esac
  case "$ARGV" in
    *ELBUKOTT*) pass "the message says the verification failed" ;;
    *)          fail "the alert text no longer names the failure" ;;
  esac
else
  fail "no alert was sent at all"; sed 's/^/        /' "$AOUT"
fi

if grep -q "failure alert delivered to chief-of-this-install" "$AOUT"; then
  pass "a successful delivery is reported in the log"
else
  fail "a successful delivery says nothing -- the log cannot distinguish sent from skipped"
fi

# --- (2) the whole point: a FAILED send must be loud ------------------------
echo
echo "(2) a send that FAILS must say so -- this is the bug the card is about"
B="$BASE/senderr"
mkinstall "$B" "chief-of-this-install" 1
BOUT="$BASE/senderr.out"
HOME="$H" BACKUP_DIR="$B/backups" bash "$B/scripts/backup.sh" > "$BOUT" 2>&1
BRC=$?
if [ "$BRC" -eq 6 ]; then
  pass "a failed alert does NOT change the exit code (still 6, the real failure)"
else
  fail "the exit code moved to $BRC -- a messaging problem is masking the backup failure"
fi
if grep -q "was NOT delivered" "$BOUT"; then
  pass "the undelivered alert is reported loudly"
else
  fail "the send failed and the script said nothing -- the original bug"
  sed 's/^/        /' "$BOUT"
fi
if grep -q "nobody has been told" "$BOUT"; then
  pass "and it spells out the consequence, not just the error"
else
  fail "the warning does not say what it costs"
fi

# --- (3) a missing helper must not crash the backup -------------------------
echo
echo "(3) no agent-msg.sh at all: report it, do not crash"
C="$BASE/nohelper"
mkinstall "$C" "chief-of-this-install" 0
chmod -x "$C/scripts/agent-msg.sh"
COUT="$BASE/nohelper.out"
HOME="$H" BACKUP_DIR="$C/backups" bash "$C/scripts/backup.sh" > "$COUT" 2>&1
CRC=$?
if [ "$CRC" -eq 6 ]; then pass "still exits 6 with no helper present"
else fail "expected exit 6, got $CRC"; sed 's/^/        /' "$COUT"; fi
if grep -q "agent-msg.sh is missing or not executable" "$COUT"; then
  pass "the missing helper is named in the log"
else
  fail "the helper was skipped silently -- indistinguishable from a delivered alert"
fi

# --- (4) the default recipient when .env says nothing -----------------------
echo
echo "(4) no MAIN_AGENT_ID in .env: fall back the way src/env.ts does"
D="$BASE/defaulted"
mkinstall "$D" "ignored" 0
printf 'SOMETHING_ELSE=1\n' > "$D/.env"
DOUT="$BASE/defaulted.out"
HOME="$H" BACKUP_DIR="$D/backups" bash "$D/scripts/backup.sh" > "$DOUT" 2>&1
if [ -f "$D/alert-argv.txt" ] && [ "$(awk '{print $1}' "$D/alert-argv.txt")" = "marveen" ]; then
  pass "falls back to the documented default (marveen), not to an empty recipient"
else
  fail "fallback recipient is '$(awk '{print $1}' "$D/alert-argv.txt" 2>/dev/null)' -- an empty or wrong name means nobody is told"
fi

# --- (5) a GREEN backup must not send an alert ------------------------------
echo
echo "(5) control: a backup that verifies must alert nobody"
E="$BASE/green"
mkdir -p "$E/scripts" "$E/store" "$E/backups"
cp "$SRC_BACKUP_SH" "$E/scripts/backup.sh"     # unmutated: the staging copy works
printf 'db\n' > "$E/store/claudeclaw.db"
printf 'MAIN_AGENT_ID=chief-of-this-install\n' > "$E/.env"
cat > "$E/scripts/agent-msg.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$E/alert-argv.txt"
exit 0
STUB
chmod +x "$E/scripts/agent-msg.sh"
EOUT="$BASE/green.out"
HOME="$H" BACKUP_DIR="$E/backups" bash "$E/scripts/backup.sh" > "$EOUT" 2>&1
ERC=$?
if [ "$ERC" -eq 0 ]; then pass "the control backup verifies (exit 0)"
else fail "the control backup failed (exit $ERC) -- (5) proves nothing"; sed 's/^/        /' "$EOUT"; fi
if [ -f "$E/alert-argv.txt" ]; then
  fail "a SUCCESSFUL backup sent a failure alert"
else
  pass "no alert on a green run"
fi

echo
echo "========================"
echo "backup-failure-alert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
