#!/bin/bash
# Does the archive RESTORE into a usable install -- not just contain the names?
#
# WHY THIS EXISTS (2026-09-21, card f213320b). backup.sh verifies the archive
# against its own manifest: every intended entry has a matching path inside. That
# answers "is it in there", which is not the question. The question is whether
# the EXTRACTED state can be worked with. The two come apart, and the split is
# not theoretical:
#
#   THE DECISIVE CASE. store/claudeclaw.db is a WAL-mode SQLite database, and the
#   WAL checkpoint at the top of backup.sh is guarded by `command -v sqlite3`.
#   The sqlite3 CLI is NOT installed on this host and is not an installer
#   dependency, so the checkpoint never runs and the newest rows live only in
#   claudeclaw.db-wal. Drop that one file and the restored database still opens,
#   still reports `integrity_check = ok`, and is quietly short. Measured on the
#   real store 2026-09-21: 369/74/808 rows with the -wal, 364/72/803 without --
#   5 memories, 2 cards and 5 messages gone, with nothing anywhere saying so.
#   A manifest check cannot see this, because the manifest never promised the
#   rows. Only opening the restored database can.
#
# So every assertion here is about the extracted tree, and the ones that matter
# compare CONTENT (row counts, bytes, a git fetch), never presence.
#
# Everything runs in a throwaway fake install with a fake $HOME: no real store,
# no real secrets, no real ~/.claude, and BACKUP_DIR points into the temp tree
# so the retention sweep can never touch a real archive.
#
# CONTAMINATION, learned the hard way the same day: opening a WAL-mode database
# checkpoints it and REMOVES the -wal/-shm files. A file-level comparison run
# after a database probe is therefore measuring the probe, not the backup. Every
# probe below works on its own copy, and the WAL-less control is built by
# EXTRACTING LESS, never by deleting from a good extraction.
set -uo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

INSTALL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(mktemp -d -t backup-restore.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "backup-restore: python3 missing, cannot build the SQLite fixture" >&2
  exit 1
fi

# --- helper: a WAL-mode DB whose newest rows are ONLY in the -wal ------------
# Closing the last connection makes SQLite checkpoint, which would fold the WAL
# back into the main file and leave this suite measuring nothing at all. So the
# second batch is committed with autocheckpoint off and the process leaves via
# os._exit(), which never runs the connection teardown.
cat > "$BASE/mkwal.py" <<'PY'
import os, sqlite3, sys
path, in_main, in_wal = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
con = sqlite3.connect(path)
con.execute("PRAGMA journal_mode=WAL")
con.execute("CREATE TABLE memories (id INTEGER PRIMARY KEY, body TEXT)")
con.execute("CREATE TABLE kanban_cards (id INTEGER PRIMARY KEY, title TEXT)")
con.execute("CREATE TABLE agent_messages (id INTEGER PRIMARY KEY, content TEXT)")
for i in range(in_main):
    con.execute("INSERT INTO memories (body) VALUES (?)", ("main-%d" % i,))
    con.execute("INSERT INTO kanban_cards (title) VALUES (?)", ("card-%d" % i,))
    con.execute("INSERT INTO agent_messages (content) VALUES (?)", ("msg-%d" % i,))
con.commit()
con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
con.close()
con = sqlite3.connect(path)
con.execute("PRAGMA wal_autocheckpoint=0")
for i in range(in_wal):
    con.execute("INSERT INTO memories (body) VALUES (?)", ("wal-%d" % i,))
    con.execute("INSERT INTO kanban_cards (title) VALUES (?)", ("walcard-%d" % i,))
    con.execute("INSERT INTO agent_messages (content) VALUES (?)", ("walmsg-%d" % i,))
con.commit()
sys.stdout.flush()
os._exit(0)
PY

# --- helper: probe a restored DB on a COPY, never in place -------------------
# Prints "<memories> <kanban_cards> <agent_messages> <integrity> <journal_mode>"
# or "UNUSABLE <error>". The copy is what keeps the probe from checkpointing the
# tree the next assertion is about to look at.
cat > "$BASE/probe.py" <<'PY'
import os, shutil, sqlite3, sys, tempfile
src = sys.argv[1]
d = os.path.dirname(src) or "."
name = os.path.basename(src)
tmp = tempfile.mkdtemp(prefix="probe.")
try:
    for f in os.listdir(d):
        if f == name or f.startswith(name + "-"):
            shutil.copy2(os.path.join(d, f), os.path.join(tmp, f))
    con = sqlite3.connect(os.path.join(tmp, name))
    counts = [con.execute("SELECT count(*) FROM %s" % t).fetchone()[0]
              for t in ("memories", "kanban_cards", "agent_messages")]
    integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
    journal = con.execute("PRAGMA journal_mode").fetchone()[0]
    con.close()
    print("%d %d %d %s %s" % (counts[0], counts[1], counts[2], integrity, journal))
except Exception as exc:                      # noqa: BLE001 -- the result IS the error
    print("UNUSABLE %s" % exc)
PY

# --- the fake install --------------------------------------------------------
# backup.sh resolves REPO_ROOT as dirname($0)/.. -- the copy MUST sit at
# <fake>/scripts/backup.sh or REPO_ROOT becomes "/" and the run is meaningless.
F="$BASE/install"
mkdir -p "$F/scripts" "$F/store" "$F/backups" \
         "$F/agents/someagent/reports" "$F/agents/someagent/.claude-config" \
         "$F/assets/meetings"
cp "$INSTALL_DIR/scripts/backup.sh" "$F/scripts/backup.sh"

python3 "$BASE/mkwal.py" "$F/store/claudeclaw.db" 10 5
SRC_ROWS="$(python3 "$BASE/probe.py" "$F/store/claudeclaw.db")"

printf 'bearer-xyz' > "$F/store/.dashboard-token"; chmod 600 "$F/store/.dashboard-token"
printf '{"entries":{"gh":{"v":"secret"}}}' > "$F/store/vault.json"; chmod 600 "$F/store/vault.json"
printf 'AAAAKEYAAAA' > "$F/store/.vault-key"; chmod 600 "$F/store/.vault-key"
printf '{"level":3}' > "$F/store/autonomy-config.json"
printf 'runtime noise\n' > "$F/store/dashboard.log"
printf 'TOKEN=abc\n' > "$F/.env"; chmod 600 "$F/.env"

# agents/: the fleet's own work, plus a symlink -- see section (7).
printf '# a report\nbody\n' > "$F/agents/someagent/reports/r.md"
printf 'identity\n' > "$F/agents/someagent/CLAUDE.md"
ln -s "../../../home/.claude/settings.json" "$F/agents/someagent/.claude-config/settings.json"

# An agent with its OWN .claude-config/projects (a real directory, not the
# legacy symlink), holding one real memory, one EMPTY memory dir, and a
# transcript sibling that must stay out -- see section (7b).
mkdir -p "$F/agents/ownagent/.claude-config/projects/-slug-a/memory" \
         "$F/agents/ownagent/.claude-config/projects/-slug-empty/memory"
printf -- '---\nname: own-memory\ndescription: the agent wrote this itself\n---\n\nthe fact.\n' \
  > "$F/agents/ownagent/.claude-config/projects/-slug-a/memory/own-memory.md"
printf '{"transcript":"25 MB of this in real life"}\n' \
  > "$F/agents/ownagent/.claude-config/projects/-slug-a/session.jsonl"
printf 'identity\n' > "$F/agents/ownagent/CLAUDE.md"
# And an agent still on the LEGACY shape: projects is a symlink into the shared
# ~/.claude/projects. find must not follow it, or the shared store lands in the
# archive a second time, once per agent.
mkdir -p "$F/agents/linkagent/.claude-config"
ln -s "$BASE/home/.claude/projects" "$F/agents/linkagent/.claude-config/projects"
printf 'identity\n' > "$F/agents/linkagent/CLAUDE.md"

# a real git repo with a local-only branch, so the bundle path is exercised
( cd "$F" && git init -q . \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "root" \
  && git checkout -q -b local-only \
  && echo "only here" > local-only.txt && git add local-only.txt \
  && git -c user.email=t@t -c user.name=t commit -q -m "a commit that exists nowhere else" ) >/dev/null 2>&1

# --- the fake $HOME ----------------------------------------------------------
H="$BASE/home"
C="$H/.claude"
mkdir -p "$C/hooks" "$C/skills/s" "$C/scheduled-tasks" \
         "$C/projects/proj/memory" "$C/channels/telegram"
printf 'import sys\n'             > "$C/hooks/a_hook.py"
printf '{"hooks":{"Stop":[]}}'    > "$C/settings.json"
printf '{"mcpServers":{}}'        > "$H/.claude.json"
printf 'skill\n'                  > "$C/skills/s/SKILL.md"
printf '{"cron":"0 8 * * *"}\n'   > "$C/scheduled-tasks/t.json"
printf -- '---\nname: a-memory\ndescription: one fact\n---\n\nthe fact itself.\n' \
                                  > "$C/projects/proj/memory/a-memory.md"
printf -- '- [A memory](a-memory.md) -- hook\n' > "$C/projects/proj/memory/MEMORY.md"
printf 'BOT_TOKEN=123\n'          > "$C/channels/telegram/.env"; chmod 600 "$C/channels/telegram/.env"
printf '{"allowFrom":["42"]}'     > "$C/channels/telegram/access.json"

echo "backup-restore"
echo "=============="
echo "  source db: $SRC_ROWS"

# --- run the backup ----------------------------------------------------------
OUT="$BASE/run.out"
HOME="$H" BACKUP_DIR="$F/backups" bash "$F/scripts/backup.sh" > "$OUT" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then pass "backup.sh exits 0 on the fake install"
else fail "backup.sh exit=$RC"; sed 's/^/        /' "$OUT"; fi

ARCHIVE="$(ls -1t "$F/backups"/claudeclaw-*.tar.gz 2>/dev/null | head -1)"
if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then pass "an archive was written"
else fail "no archive in $F/backups"; echo "nothing to restore, aborting"; exit 1; fi

# --- the restore itself ------------------------------------------------------
# -p because the 0600 modes on the secrets are part of what has to survive.
R="$BASE/restored"
mkdir -p "$R"
if tar -xpzf "$ARCHIVE" -C "$R" 2>"$BASE/extract.err"; then
  pass "the archive extracts without error"
else
  fail "extraction failed"; sed 's/^/        /' "$BASE/extract.err"
fi

echo
echo "(1) the database -- the decisive case"
GOT="$(python3 "$BASE/probe.py" "$R/repo/store/claudeclaw.db")"
echo "        restored db: $GOT"
case "$GOT" in
  UNUSABLE*) fail "the restored database does not open: $GOT" ;;
  *)         pass "the restored database opens" ;;
esac
if [ "$GOT" = "$SRC_ROWS" ]; then
  pass "row counts match the source exactly ($SRC_ROWS)"
else
  fail "row counts differ -- source [$SRC_ROWS] vs restored [$GOT]"
fi
case "$GOT" in
  *" ok "*) pass "integrity_check = ok" ;;
  *)        fail "integrity_check is not ok: $GOT" ;;
esac
# NOT `tar -tzf ... | grep -q`: with `set -o pipefail` on, grep's early exit
# gives tar a SIGPIPE and the PIPELINE reports failure, so the check goes red at
# random on a perfectly good archive. Measured here 2026-09-21: it passed once
# and failed on the next four runs. Rule 1, on the test itself.
LIST="$BASE/list.txt"
tar -tzf "$ARCHIVE" > "$LIST"
if grep -qx 'repo/store/claudeclaw.db-wal' "$LIST"; then
  pass "the archive carries claudeclaw.db-wal"
else
  fail "claudeclaw.db-wal is NOT in the archive -- see the control below"
fi

echo
echo "(2) the control: what the -wal is actually holding up"
# Built by extracting LESS, not by deleting from the good tree. If this control
# ever stops showing a loss, the fixture has stopped reproducing the live
# condition (an uncheckpointed WAL) and section (1) is no longer proving
# anything -- which is why the control asserts the loss instead of tolerating it.
W="$BASE/restored-nowal"
mkdir -p "$W"
tar -xpzf "$ARCHIVE" -C "$W" --exclude 'repo/store/claudeclaw.db-wal' 2>/dev/null
NOWAL="$(python3 "$BASE/probe.py" "$W/repo/store/claudeclaw.db")"
echo "        without the -wal: $NOWAL"
if [ "$NOWAL" != "$GOT" ]; then
  pass "dropping the -wal silently loses rows ([$GOT] -> [$NOWAL])"
else
  fail "the WAL-less restore is identical -- the fixture no longer has an uncheckpointed WAL"
fi
case "$NOWAL" in
  *" ok "*) pass "and it STILL reports integrity_check = ok, so the loss is silent" ;;
  *)        fail "expected a structurally valid but short database, got: $NOWAL" ;;
esac

echo
echo "(3) the credential vault -- both halves or neither is any use"
for p in repo/store/vault.json repo/store/.vault-key repo/store/.dashboard-token repo/.env; do
  if [ -f "$R/$p" ]; then pass "restored: $p"; else fail "MISSING: $p"; fi
done
if [ -f "$R/repo/store/vault.json" ] && [ -f "$R/repo/store/.vault-key" ]; then
  pass "vault.json and .vault-key came back TOGETHER (either alone is worthless)"
else
  fail "the vault pair is incomplete"
fi
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$R/repo/store/vault.json" 2>/dev/null; then
  pass "the restored vault.json parses as JSON"
else
  fail "the restored vault.json does not parse"
fi

echo
echo "(4) file modes survive the round trip"
for p in repo/store/.vault-key repo/store/.dashboard-token repo/.env home/.claude/channels/telegram/.env; do
  if [ -f "$R/$p" ]; then
    M="$(stat -c '%a' "$R/$p" 2>/dev/null)"
    if [ "$M" = "600" ]; then pass "0600 preserved: $p"
    else fail "$p came back as $M, not 600 -- a secret is world-readable after a restore"; fi
  else
    fail "cannot check the mode, missing: $p"
  fi
done

echo
echo "(5) the file-based memories -- present AND byte-identical"
# 2026-09-04: 490 markdown memories, none of them in the tarball, and the backup
# said nothing. Presence alone is not the property; a truncated copy would pass
# a presence check and lose the fact.
for p in .claude/projects/proj/memory/a-memory.md .claude/projects/proj/memory/MEMORY.md; do
  if [ -f "$R/home/$p" ]; then
    if cmp -s "$H/$p" "$R/home/$p"; then pass "byte-identical: $p"
    else fail "CONTENT DIFFERS after restore: $p"; fi
  else
    fail "MISSING: $p"
  fi
done
FM="$(sed -n '1p' "$R/home/.claude/projects/proj/memory/a-memory.md")"
if [ "$FM" = "---" ]; then
  pass "the frontmatter is intact (the memory is still loadable)"
else
  fail "the frontmatter is gone -- the file survived, the memory did not"
fi

echo
echo "(6) \$HOME config that nothing else can reconstruct"
for p in .claude/hooks/a_hook.py .claude/settings.json .claude.json \
         .claude/skills/s/SKILL.md .claude/scheduled-tasks/t.json \
         .claude/channels/telegram/access.json; do
  if [ -f "$R/home/$p" ] && cmp -s "$H/$p" "$R/home/$p"; then pass "restored, byte-identical: $p"
  else fail "missing or changed: $p"; fi
done

echo
echo "(7) agents/ -- the team's own output, and the symlink limit"
for p in someagent/reports/r.md someagent/CLAUDE.md; do
  if [ -f "$R/repo/agents/$p" ] && cmp -s "$F/agents/$p" "$R/repo/agents/$p"; then
    pass "restored, byte-identical: agents/$p"
  else fail "missing or changed: agents/$p"; fi
done
# A NAMED LIMIT, pinned on purpose. The agents/ list is built with
# `find -type f`, which does not match symlinks, so the .claude-config symlink
# farm is not carried. Their TARGETS are carried under home/, so nothing is
# lost, but the links themselves have to be recreated by the scaffold after a
# restore. This asserts the behaviour rather than assuming it: if someone makes
# the find follow symlinks, the archive starts carrying duplicated content and
# this speaks up.
#
# TWO CORRECTIONS to what this block said when it was written, both measured
# 2026-09-25 (card 504cd72d):
#   - the count was given as "42 on the live tree 2026-09-21". It is 173 today
#     (`find agents -type l`), and 167 of those links predate 2026-09-22, so it
#     was ~167 on the day the 42 was written, not 42. The figure was wrong by
#     four times; the behaviour it describes was not.
#   - the fixture makes .claude-config/settings.json a SYMLINK, which is the one
#     thing it is NOT in a real farm: the provisioner WRITES that file (and
#     .claude.json, plugins/known_marketplaces.json, plugins/installed_plugins
#     .json) as a regular file, so `find -type f` matches it and the archive
#     DOES carry it -- correctly, it is per-agent state nothing re-derives. The
#     assertion below is still a valid symlink-following probe, but read it as
#     "this link is not followed", never as ".claude-config is skipped".
# Whether the scaffold actually rebuilds the farm after a restore -- the question
# this block could not answer -- is measured in backup-restore-symlinks.test.sh.
if [ -e "$R/repo/agents/someagent/.claude-config/settings.json" ]; then
  fail "a .claude-config symlink WAS carried -- the find now follows symlinks, re-measure the archive size and the duplication"
else
  pass "the .claude-config symlink is not carried (known: find -type f skips it; the target is under home/)"
fi
if [ -f "$R/home/.claude/settings.json" ]; then
  pass "and the symlink's TARGET is in the archive, so the content is not lost"
else
  fail "the symlink is skipped AND its target is missing -- that IS a loss"
fi


echo
echo "(7b) an agent's OWN memory -- the trap that costs nothing today"
# Card 475fc6c8. The agents/ rule excludes .claude-config/projects/** by path,
# which is right for the transcripts (56 MB under leandev alone) and wrong for
# the memory/ directories inside it. Measured 2026-09-25 on the live tree: 8 such
# directories exist, all under leandev, ALL EMPTY, and the other six agents still
# symlink projects into the main agent's store. So the gap costs nothing TODAY --
# and the day one of them is switched to its own directory, its memories would
# start landing outside every archive with nothing saying so. This section is
# what makes that day loud instead of silent.
P_OWN="agents/ownagent/.claude-config/projects/-slug-a/memory/own-memory.md"
if [ -f "$R/repo/$P_OWN" ] && cmp -s "$F/$P_OWN" "$R/repo/$P_OWN"; then
  pass "restored, byte-identical: an agent's own memory file"
else
  fail "an agent's own .claude-config/projects/*/memory file did NOT come back"
fi
# The exclusion must still hold for everything else in that tree -- the whole
# point is to take memory/ back WITHOUT taking the transcripts with it.
if [ -e "$R/repo/agents/ownagent/.claude-config/projects/-slug-a/session.jsonl" ]; then
  fail "the transcript sibling was carried too -- the exclusion no longer holds, re-measure the archive size"
else
  pass "the transcript next to it stayed out (memory/ is taken back, the tree is not)"
fi
# An empty memory/ is the common case right now, and a directory with no files
# is exactly the thing tar can drop without anyone noticing.
if [ -d "$R/repo/agents/ownagent/.claude-config/projects/-slug-empty/memory" ]; then
  pass "an EMPTY memory/ still comes back as a directory"
else
  fail "an empty memory/ vanished in the round trip -- the restored agent has no place to write"
fi
# The legacy shape: projects is a symlink into the shared store. find must not
# follow it; if it does, the shared memories are archived once per agent.
if [ -e "$R/repo/agents/linkagent/.claude-config/projects" ]; then
  fail "the symlinked projects WAS followed -- the shared store is now duplicated per agent"
else
  pass "a symlinked projects/ contributes nothing (its content is carried once, under home/)"
fi

echo
echo "(8) the git bundle -- local-only commits actually come back"
# 2026-09-04 assumed the source lives on a remote. It does not: this install has
# local branches that were never pushed. `bundle verify` proves the file is
# readable; only a real fetch proves the commit is recoverable.
B="$R/repo/local-commits.bundle"
if [ -f "$B" ]; then
  pass "local-commits.bundle is in the archive"
  if git bundle verify "$B" >/dev/null 2>&1; then pass "git bundle verify passes"
  else fail "git bundle verify failed"; fi
  V="$BASE/verify-repo"
  mkdir -p "$V"
  if ( cd "$V" && git init -q --bare . \
       && git fetch -q "$B" 'refs/heads/*:refs/heads/*' ) >/dev/null 2>&1; then
    FETCHED="$( cd "$V" && git cat-file -p local-only:local-only.txt 2>/dev/null )"
    if [ "$FETCHED" = "only here" ]; then
      pass "the local-only commit fetches out of the bundle with its content intact"
    else
      fail "the bundle fetched but the file content did not come back"
    fi
  else
    fail "could not fetch the branches out of the bundle"
  fi
else
  fail "no local-commits.bundle -- local-only commits would be lost"
fi

echo
echo "(9) the runtime noise stayed out"
if [ -e "$R/repo/store/dashboard.log" ]; then
  fail "a *.log came back -- the exclusion no longer works"
else
  pass "*.log is not restored"
fi

echo
echo "(10) mutation: dropping the -wal must FAIL the backup"
# THE FINDING OF THIS CARD, and then its fix. Until 2026-09-21 the load-bearing
# markers named repo/store/claudeclaw.db and nothing else, which reads as "the
# database is protected". It was not: an archive built without the -wal exited 0,
# looked perfect, verified clean against its own manifest, and restored into a
# database that opens, says integrity_check = ok and is quietly short. A manifest
# check cannot see it, because the manifest never promised the rows. So backup.sh
# now names the -wal too, existence-guarded, and this control is what proves the
# guard actually fires -- a guard nobody has seen fail is indistinguishable from
# one that never fires.
G="$BASE/install-mut"
mkdir -p "$G/scripts" "$G/backups"
cp -a "$F/store" "$G/store"
cp -a "$F/agents" "$G/agents"
cp -p "$F/.env" "$G/.env"
sed "s|case \"\${_name}\" in \*.log|case \"\${_name}\" in *.db-wal\|*.log|" \
  "$F/scripts/backup.sh" > "$G/scripts/backup.sh"
if grep -q '\*.db-wal' "$G/scripts/backup.sh"; then
  MOUT="$BASE/mut.out"
  HOME="$H" BACKUP_DIR="$G/backups" bash "$G/scripts/backup.sh" > "$MOUT" 2>&1
  MRC=$?
  if [ "$MRC" -eq 6 ]; then pass "an archive without the -wal exits 6"
  else fail "dropping the -wal gave exit=$MRC, expected 6"; sed 's/^/        /' "$MOUT"; fi
  if grep -q 'MISSING load-bearing item: repo/store/claudeclaw.db-wal' "$MOUT"; then
    pass "and it names the -wal, not just 'something is missing'"
  else fail "no load-bearing message naming the -wal"; sed 's/^/        /' "$MOUT"; fi
else
  fail "the mutation did not apply -- test (10) measured nothing"
fi

echo
echo "(10b) a store with no -wal at all must still back up"
# The guard is existence-based on purpose. A host that HAS the sqlite3 CLI
# checkpoints the WAL away at the top of the script and has nothing left to
# carry; failing its backup over an absent -wal would teach everyone to ignore
# the failure. Same reasoning as the hooks/settings.json guards above.
K="$BASE/install-nowal"
mkdir -p "$K/scripts" "$K/store" "$K/backups"
cp "$F/scripts/backup.sh" "$K/scripts/backup.sh"
python3 - "$K/store/claudeclaw.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE memories (id INTEGER PRIMARY KEY)")
con.commit()
con.close()
PY
KOUT="$BASE/nowal.out"
HOME="$H" BACKUP_DIR="$K/backups" bash "$K/scripts/backup.sh" > "$KOUT" 2>&1
KRC=$?
if [ "$KRC" -eq 0 ]; then pass "a checkpointed store (no -wal on disk) still backs up"
else fail "a store with no -wal exited $KRC"; sed 's/^/        /' "$KOUT"; fi

echo
echo "(11) mutation: a silently empty staging copy must not pass"
# stage_group is the one place where a copy can do nothing and leave the archive
# structurally fine. backup.sh verifies every manifest entry against the archive
# listing, so this must fail the backup, not produce a green one.
E="$BASE/install-mut2"
mkdir -p "$E/scripts" "$E/backups"
cp -a "$F/store" "$E/store"
cp -p "$F/.env" "$E/.env"
sed 's|    cp -pR "${base}/${rel}" "${STAGE}/${group}/${parent}/"|    true|' \
  "$F/scripts/backup.sh" > "$E/scripts/backup.sh"
if ! grep -q 'cp -pR "${base}/${rel}"' "$E/scripts/backup.sh"; then
  EOUT="$BASE/mut2.out"
  HOME="$H" BACKUP_DIR="$E/backups" bash "$E/scripts/backup.sh" > "$EOUT" 2>&1
  ERC=$?
  if [ "$ERC" -ne 0 ]; then pass "a staging copy that does nothing fails the backup (exit=$ERC)"
  else fail "a backup that copied NOTHING exited 0"; sed 's/^/        /' "$EOUT"; fi
else
  fail "mutation 2 did not apply -- test (11) measured nothing"
fi


echo
echo "(11b) mutation: dropping the agents-memory rule must FAIL the backup"
# The rule added for card 475fc6c8 is only worth having if its ABSENCE is loud.
# backup.sh carries a load-bearing check for it, guarded on a memory directory
# that actually holds a file -- so remove the rule, keep the check, and the
# backup must refuse. Measured first by hand 2026-09-25: exit 6, and the archive
# really did lose own-memory.md. The mutation runs on a COPY; the live
# scripts/backup.sh is never patched, so a scheduled backup can never hit a
# momentarily broken script.
M="$BASE/install-mut3"
mkdir -p "$M/scripts" "$M/backups"
cp -a "$F/store" "$M/store"
cp -a "$F/agents" "$M/agents"
cp -p "$F/.env" "$M/.env"
python3 - "$F/scripts/backup.sh" "$M/scripts/backup.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
rule = """if [[ -d agents ]]; then
  find agents -maxdepth 6 -path '*/.claude-config/projects/*' -type d -name memory \\
    -print >> "${REPOLIST}"
fi"""
open(dst, 'w').write(s.replace(rule, "# MUTATED: the agents-memory rule is gone"))
if rule not in s: print("MUTATION SOURCE NOT FOUND")
PY
if ! grep -q "maxdepth 6 -path '\*/\.claude-config/projects/\*' -type d -name memory" "$M/scripts/backup.sh"; then
  MOUT="$BASE/mut3.out"
  HOME="$H" BACKUP_DIR="$M/backups" bash "$M/scripts/backup.sh" > "$MOUT" 2>&1
  MRC=$?
  if [ "$MRC" -ne 0 ]; then
    pass "removing the agents-memory rule fails the backup (exit=$MRC)"
  else
    fail "the backup went green WITHOUT carrying any agent's own memory"
    sed 's/^/        /' "$MOUT"
  fi
  # And prove the mutation actually removed content, not just tripped a check:
  # a guard that fires on an archive which is fine anyway proves nothing.
  MARC="$(ls -1t "$M/backups"/claudeclaw-*.tar.gz 2>/dev/null | head -1)"
  if [ -n "$MARC" ] && tar -tzf "$MARC" | grep -q 'agents/ownagent/.claude-config/projects/-slug-a/memory/own-memory.md'; then
    fail "the mutated archive still holds the memory file -- (11b) measured nothing"
  else
    pass "and the mutated archive really is missing the memory file"
  fi
else
  fail "mutation 3 did not apply -- test (11b) measured nothing"
fi

echo
echo "========================"
echo "backup-restore: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
