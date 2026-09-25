#!/bin/bash
# Does the .claude-config SYMLINK FARM come back after a restore -- or only its
# targets?
#
# WHY THIS EXISTS (2026-09-25, card 504cd72d). f213320b proved the DATA
# restores: the archive's rows match the source and the -wal marker closed the
# silent-loss path. It also named what it did NOT prove, and this is that:
#
#   backup.sh builds its agents/ list with `find agents -type f`, which does not
#   match symlinks. Every agent's .claude-config is a farm of links into
#   ~/.claude, so the LINKS are not in the archive -- only their targets, under
#   home/. Nothing had ever checked that the provisioner puts them back. The
#   restore was therefore verified on the data side and ASSUMED on the structure
#   side, which is the same shape the earlier card found one level down.
#
# So this suite runs the real thing end to end in a throwaway tree:
#   scaffold -> backup -> extract -> scaffold again on the EXTRACTED tree
#   -> compare the farm link-for-link, target-for-target.
#
# THE ANSWER IS NOT A PLAIN YES, and the interesting half is section (5). The
# provisioner iterates `readdirSync(~/.claude)`: it can only link what is THERE.
# backup.sh excludes a dozen ~/.claude subtrees (cache, sessions, file-history,
# plugins/cache, ...), and a directory whose every file is excluded does not
# exist in the archive at all -- tar carries no entry for it. Those links come
# back MISSING, silently. They are all regenerable, and the farm self-heals on
# the next spawn once Claude Code recreates the directory, so this is a bounded
# gap rather than a loss -- but it is a gap, and section (5) pins the exact set
# so a NEW one cannot arrive quietly.
#
# Nothing here touches the live install: fake repo root, fake $HOME, BACKUP_DIR
# inside the temp tree, and the provisioner is driven through tsx against a COPY
# of src/ placed in the throwaway tree (PROJECT_ROOT is derived from the module's
# own location, so the copy is what makes it write there and not here).
set -uo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

INSTALL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(mktemp -d -t backup-restore-symlinks.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

# Mutation seam, defaults to the live tree. A suite whose own assertions cannot
# be shown to go red is decoration, and both halves here (the backup filter and
# the provisioner) live in files the running install uses -- mutating those in
# place to prove discrimination would put a real scheduled backup at risk. These
# two variables let an external mutation run point at patched COPIES instead.
# CI never sets them; the defaults are the only thing that ships.
SRC_BACKUP_SH="${SRC_BACKUP_SH:-$INSTALL_DIR/scripts/backup.sh}"
SRC_TREE="${SRC_TREE:-$INSTALL_DIR/src}"

TSX="$INSTALL_DIR/node_modules/.bin/tsx"
if [ ! -x "$TSX" ]; then
  echo "SKIP-SUITE: tsx -- DONTES: a scaffold (provisionIsolatedConfigDir) TypeScript, es a suite nem forditja le magat; tsx nelkul a symlink-farm ujraepitese nem merheto. docs/hianyzo-eszkozok-es-skip.md"
  exit 77
fi

echo "backup-restore-symlinks"
echo "======================="

# --- the fake install --------------------------------------------------------
# backup.sh resolves REPO_ROOT as dirname($0)/.., so its copy MUST sit at
# <fake>/scripts/backup.sh. src/ is copied (without its own tests) because
# src/config.ts computes PROJECT_ROOT from __dirname -- that copy is the only
# thing keeping the provisioner off the real tree.
F="$BASE/install"
mkdir -p "$F/scripts" "$F/store" "$F/backups" "$F/agents/probe1" "$F/agents/probe2"
cp "$SRC_BACKUP_SH" "$F/scripts/backup.sh"
cp "$INSTALL_DIR/package.json" "$F/package.json"
[ -f "$INSTALL_DIR/tsconfig.json" ] && cp "$INSTALL_DIR/tsconfig.json" "$F/tsconfig.json"
ln -s "$INSTALL_DIR/node_modules" "$F/node_modules"
mkdir -p "$F/src"
( cd "$SRC_TREE" && tar -cf - --exclude='__tests__' . ) | ( cd "$F/src" && tar -xf - )
printf 'probe one\n' > "$F/agents/probe1/CLAUDE.md"
printf 'probe two\n' > "$F/agents/probe2/CLAUDE.md"
printf 'x' > "$F/store/claudeclaw.db"

# --- the fake $HOME ----------------------------------------------------------
# One entry of every class the provisioner and backup.sh treat differently.
H="$BASE/home"
C="$H/.claude"
# carried: a real file lives in each, and no exclusion matches it
mkdir -p "$C/hooks" "$C/skills/s" "$C/scheduled-tasks" "$C/tools" "$C/backups" \
         "$C/channels/telegram" "$C/plugins/data"
printf 'import sys\n'           > "$C/hooks/a_hook.py"
printf 'skill\n'                > "$C/skills/s/SKILL.md"
printf '{"cron":"0 8 * * *"}\n' > "$C/scheduled-tasks/t.json"
printf 'tool\n'                 > "$C/tools/t.sh"
printf 'old\n'                  > "$C/backups/b.json"
printf '{"allowFrom":["42"]}'   > "$C/channels/telegram/access.json"
printf '{"state":1}'            > "$C/plugins/data/d.json"
printf '{"hooks":{"Stop":[]}}'  > "$C/settings.json"
printf '{"limits":1}'           > "$C/policy-limits.json"
printf '{"remote":1}'           > "$C/remote-settings.json"
printf '1789000000'             > "$C/.last-cleanup"
printf '{}'                     > "$C/plugins/known_marketplaces.json"
printf '{"plugins":{}}'         > "$C/plugins/installed_plugins.json"
printf '{"mcpServers":{}}'      > "$H/.claude.json"
# NOT carried: every file inside is excluded, so tar gets no entry for the dir
mkdir -p "$C/cache" "$C/sessions" "$C/session-env" "$C/downloads" "$C/tmp" \
         "$C/paste-cache" "$C/file-history" "$C/shell-snapshots" "$C/logs" \
         "$C/plugins/cache" "$C/plugins/marketplaces" "$C/projects/p/memory"
printf 'x' > "$C/cache/c"; printf 'x' > "$C/sessions/s"; printf 'x' > "$C/session-env/e"
printf 'x' > "$C/downloads/d"; printf 'x' > "$C/tmp/t"; printf 'x' > "$C/paste-cache/p"
printf 'x' > "$C/file-history/f"; printf 'x' > "$C/shell-snapshots/s"
printf 'noise\n' > "$C/logs/dash.log"
printf 'x' > "$C/plugins/cache/c"; printf 'x' > "$C/plugins/marketplaces/m"
printf 'transcript\n' > "$C/history.jsonl"
printf -- '---\nname: m\ndescription: d\n---\nfact\n' > "$C/projects/p/memory/m.md"

# --- the scaffold driver -----------------------------------------------------
# Enumerated, not hardcoded: listAgentNames() is what a real boot uses, so a
# change in how agents are discovered shows up here too.
cat > "$BASE/scaffold.mts" <<'TS'
const root = process.argv[2]
const cfg = await import(`${root}/src/web/agent-config.ts`)
const proc = await import(`${root}/src/web/agent-process.ts`)
const names: string[] = cfg.listAgentNames()
if (names.length === 0) { console.error('NO AGENTS FOUND'); process.exit(3) }
for (const n of names) {
  const r = proc.ensureIsolatedChannelConfigDir(n, null)
  if (r === null) { console.error(`PROVISION NULL for ${n}`); process.exit(4) }
}
console.log(`SCAFFOLDED ${names.sort().join(',')}`)
TS

# Prints "<agent>/<relpath> -> <TOKEN>/<rest>" for every link in the farm, with
# the home root replaced by a token so two trees can be compared literally.
farm() {  # $1 = repo root, $2 = home root
  ( cd "$1" && find agents -type l -printf '%p -> %l\n' 2>/dev/null ) \
    | sed "s#-> $2#-> HOME#" | LC_ALL=C sort
}

run_scaffold() {  # $1 = repo root, $2 = home root, $3 = label
  ( cd "$1" && HOME="$2" "$TSX" "$BASE/scaffold.mts" "$1" ) > "$BASE/scaffold.$3.out" 2>&1
  return $?
}

echo
echo "(1) ground truth -- the scaffold builds the farm at all"
if run_scaffold "$F" "$H" "pre"; then
  pass "the scaffold ran on the fake install (exit 0)"
else
  fail "the scaffold failed on the fake install"; sed 's/^/        /' "$BASE/scaffold.pre.out"
  echo; echo "backup-restore-symlinks: $PASS passed, $FAIL failed"; exit 1
fi
if grep -qx 'SCAFFOLDED probe1,probe2' "$BASE/scaffold.pre.out"; then
  pass "both probe agents were discovered by listAgentNames()"
else
  fail "agent discovery changed: $(tail -1 "$BASE/scaffold.pre.out")"
fi
farm "$F" "$H" > "$BASE/farm.pre"
PRE_N="$(wc -l < "$BASE/farm.pre")"
echo "        farm before backup: $PRE_N links"
if [ "$PRE_N" -ge 20 ]; then
  pass "the farm is populated ($PRE_N links across 2 agents)"
else
  fail "only $PRE_N links -- the fixture no longer exercises a farm"
fi
if [ -z "$(awk '$3 !~ /^HOME\// {print}' "$BASE/farm.pre")" ]; then
  pass "every link points inside the fake \$HOME (nothing escaped to the real one)"
else
  fail "a link points outside the fake \$HOME:"; awk '$3 !~ /^HOME\// {print "        " $0}' "$BASE/farm.pre"
fi

echo
echo "(2) the backup -- the links themselves do not travel"
OUT="$BASE/run.out"
HOME="$H" BACKUP_DIR="$F/backups" bash "$F/scripts/backup.sh" > "$OUT" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then pass "backup.sh exits 0"; else fail "backup.sh exit=$RC"; sed 's/^/        /' "$OUT"; fi
ARCHIVE="$(ls -1t "$F/backups"/claudeclaw-*.tar.gz 2>/dev/null | head -1)"
if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then pass "an archive was written"
else fail "no archive in $F/backups"; echo; echo "backup-restore-symlinks: $PASS passed, $FAIL failed"; exit 1; fi
# No `| grep -q` on tar: SIGPIPE turns a good archive red at random under
# pipefail (measured on the sibling suite 2026-09-21).
LIST="$BASE/list.txt"
tar -tzf "$ARCHIVE" > "$LIST"
# The claim is narrow and worth stating exactly, because the obvious wider one
# is FALSE: .claude-config is not skipped wholesale. The provisioner writes four
# REAL files into it (settings.json, .claude.json, plugins/known_marketplaces
# .json, plugins/installed_plugins.json) and `find -type f` matches those, so
# they are in the archive and should be -- they are per-agent state nothing else
# re-derives. What does not travel is the LINKS. Asserted name by name against
# the farm measured in (1), not against one hand-picked path.
CARRIED_LINKS=""
while IFS= read -r line; do
  lp="${line%% -> *}"
  if grep -qxF "repo/$lp" "$LIST"; then CARRIED_LINKS="$CARRIED_LINKS $lp"; fi
done < "$BASE/farm.pre"
if [ -z "$CARRIED_LINKS" ]; then
  pass "not one of the $PRE_N farm links is in the archive (find -type f skips symlinks)"
else
  fail "the find now follows symlinks -- re-measure archive size and duplication:$CARRIED_LINKS"
fi
# The positive half: the real per-agent files DO travel. Without this the
# assertion above would also pass on an archive that carried no agents/ at all.
for p in agents/probe1/.claude-config/settings.json \
         agents/probe1/.claude-config/.claude.json \
         agents/probe1/.claude-config/plugins/installed_plugins.json; do
  if grep -qxF "repo/$p" "$LIST"; then
    pass "carried (a real file, not a link): $p"
  else
    fail "MISSING from the archive: $p -- per-agent state nothing re-derives"
  fi
done

echo
echo "(3) the extracted tree -- the farm is genuinely gone"
R="$BASE/restored"
mkdir -p "$R"
if tar -xpzf "$ARCHIVE" -C "$R" 2>"$BASE/extract.err"; then
  pass "the archive extracts without error"
else
  fail "extraction failed"; sed 's/^/        /' "$BASE/extract.err"
fi
GONE="$(cd "$R/repo" 2>/dev/null && find agents -type l 2>/dev/null | wc -l)"
if [ "$GONE" -eq 0 ]; then
  pass "zero symlinks under repo/agents after extraction -- this is what has to be rebuilt"
else
  fail "$GONE links survived extraction; sections (4)-(5) would be measuring the archive, not the scaffold"
fi
for p in agents/probe1/CLAUDE.md agents/probe2/CLAUDE.md; do
  if [ -f "$R/repo/$p" ]; then pass "the agent itself restored: $p"; else fail "MISSING: $p"; fi
done

echo
echo "(4) the scaffold on the RESTORED tree -- what comes back"
# src/ is not in the archive (it lives in git, and the bundle is a separate
# restore step), so the code is placed here deliberately. NAMED LIMIT: this is
# the CURRENT working tree's src, not one rebuilt from the restored bundle --
# the suite measures the scaffold, not the source restore.
mkdir -p "$R/repo/src"
( cd "$SRC_TREE" && tar -cf - --exclude='__tests__' . ) | ( cd "$R/repo/src" && tar -xf - )
cp "$INSTALL_DIR/package.json" "$R/repo/package.json"
[ -f "$INSTALL_DIR/tsconfig.json" ] && cp "$INSTALL_DIR/tsconfig.json" "$R/repo/tsconfig.json"
ln -s "$INSTALL_DIR/node_modules" "$R/repo/node_modules"
RH="$R/home"
if run_scaffold "$R/repo" "$RH" "post"; then
  pass "the scaffold runs on the restored tree (exit 0)"
else
  fail "the scaffold failed on the restored tree"; sed 's/^/        /' "$BASE/scaffold.post.out"
fi
farm "$R/repo" "$RH" > "$BASE/farm.post"
POST_N="$(wc -l < "$BASE/farm.post")"
echo "        farm after restore: $POST_N links (was $PRE_N)"
if [ "$POST_N" -gt 0 ]; then
  pass "the scaffold rebuilt a farm ($POST_N links) -- the links are NOT lost with the archive"
else
  fail "the scaffold rebuilt nothing: the restore loses the farm outright"
fi
# Every rebuilt link must resolve, and must resolve into the RESTORED home. A
# link left pointing at the original tree is the failure mode that matters on a
# different machine or user: it resolves on the test host and nowhere else.
BADT=0; DANG=0
while IFS= read -r line; do
  lp="${line%% -> *}"; tg="${line##* -> }"
  case "$tg" in HOME/*) ;; *) BADT=$((BADT+1)); echo "        target outside the restored home: $line" ;; esac
  [ -e "$R/repo/$lp" ] || { DANG=$((DANG+1)); echo "        dangling: $line"; }
done < "$BASE/farm.post"
if [ "$BADT" -eq 0 ]; then pass "every rebuilt link points into the RESTORED \$HOME"; else fail "$BADT link(s) point outside it"; fi
if [ "$DANG" -eq 0 ]; then pass "every rebuilt link resolves to something that exists"; else fail "$DANG dangling link(s)"; fi
# The links that DID come back must be identical, not merely present.
COMMON_DIFF="$(LC_ALL=C comm -12 <(cut -d' ' -f1 "$BASE/farm.pre" | LC_ALL=C sort) \
                                 <(cut -d' ' -f1 "$BASE/farm.post" | LC_ALL=C sort) \
  | while read -r p; do
      a="$(grep -F -- "$p -> " "$BASE/farm.pre"  | head -1)"
      b="$(grep -F -- "$p -> " "$BASE/farm.post" | head -1)"
      [ "$a" = "$b" ] || echo "$p: [$a] vs [$b]"
    done)"
if [ -z "$COMMON_DIFF" ]; then
  pass "every link present in BOTH farms points at the same relative target"
else
  fail "a rebuilt link changed target:"; echo "$COMMON_DIFF" | sed 's/^/        /'
fi

echo
echo "(5) the named gap -- what the scaffold CANNOT rebuild, and why"
# The provisioner links what readdirSync(~/.claude) returns. backup.sh excludes
# these subtrees, and a directory with no carried file has no tar entry at all,
# so after a restore the entry is simply not there and no link is made. All of
# them are regenerable state; the farm self-heals on the next spawn once Claude
# Code recreates the directory. Pinned as an exact set: a NEW name appearing
# here means an exclusion started costing structure, and that is a decision, not
# a detail.
EXPECTED_MISSING="cache downloads file-history history.jsonl logs paste-cache plugins/cache plugins/marketplaces session-env sessions shell-snapshots tmp"
MISSING="$(LC_ALL=C comm -23 <(cut -d' ' -f1 "$BASE/farm.pre"  | sed 's#^agents/probe1/\.claude-config/##' | grep -v '^agents/probe2' | LC_ALL=C sort -u) \
                             <(cut -d' ' -f1 "$BASE/farm.post" | sed 's#^agents/probe1/\.claude-config/##' | grep -v '^agents/probe2' | LC_ALL=C sort -u) \
          | tr '\n' ' ' | sed 's/ *$//')"
echo "        not rebuilt: ${MISSING:-<none>}"
if [ "$MISSING" = "$EXPECTED_MISSING" ]; then
  pass "exactly the known, regenerable set is not rebuilt"
else
  fail "the gap changed"
  echo "        expected: $EXPECTED_MISSING"
  echo "        actual  : ${MISSING:-<none>}"
fi
# And the reason must be the one claimed: the TARGET is absent from the restore,
# not that the scaffold skipped an existing one.
WRONG_REASON=""
for m in $MISSING; do
  [ -e "$RH/.claude/$m" ] && WRONG_REASON="$WRONG_REASON $m"
done
if [ -z "$WRONG_REASON" ]; then
  pass "each unrebuilt link is unrebuilt because its TARGET is not in the archive"
else
  fail "the scaffold skipped a link whose target IS present:$WRONG_REASON"
fi
# The counterpart claim from f213320b: the targets that DO matter are carried.
for t in hooks/a_hook.py skills/s/SKILL.md scheduled-tasks/t.json settings.json; do
  if [ -f "$RH/.claude/$t" ]; then pass "target carried under home/: .claude/$t"; else fail "target MISSING: .claude/$t"; fi
done

echo
echo "(6) mutations -- do sections (4)-(5) actually discriminate?"
# (a) remove a restored target: the link must NOT come back. If it does, the
#     'rebuilt' verdict above was measuring leftovers rather than work.
rm -rf "$RH/.claude/skills"
rm -f  "$R/repo/agents/probe1/.claude-config/skills" "$R/repo/agents/probe2/.claude-config/skills"
if run_scaffold "$R/repo" "$RH" "mut-a"; then :; else fail "scaffold failed during mutation (a)"; fi
if [ -e "$R/repo/agents/probe1/.claude-config/skills" ]; then
  fail "a link was created for a target that no longer exists -- the check is not measuring the target"
else
  pass "a removed target yields no link (the rebuild follows the restored home, not a cache)"
fi
# (b) a stale REGULAR FILE where a link belongs: the provisioner must replace
#     it. This is the branch that keeps a half-restored tree from shadowing the
#     shared config with a frozen copy.
mkdir -p "$RH/.claude/skills"; printf 'back\n' > "$RH/.claude/skills/S.md"
# rm FIRST: `> link` follows the symlink into ~/.claude/hooks (a directory) and
# fails with "Is a directory", which would leave the original link in place and
# make the -L assertion below pass without testing anything. Measured here
# 2026-09-25 -- the mutation has to actually mutate.
rm -f "$R/repo/agents/probe1/.claude-config/hooks"
printf 'stale copy\n' > "$R/repo/agents/probe1/.claude-config/hooks"
if [ -L "$R/repo/agents/probe1/.claude-config/hooks" ]; then
  fail "the mutation did not take: still a symlink before the scaffold ran"
else
  pass "mutation in place: a regular file now sits where the link belongs"
fi
if run_scaffold "$R/repo" "$RH" "mut-b"; then :; else fail "scaffold failed during mutation (b)"; fi
if [ -L "$R/repo/agents/probe1/.claude-config/hooks" ]; then
  pass "a stale regular file in the farm is replaced by the symlink"
else
  fail "a stale regular file survived the scaffold -- it would shadow ~/.claude silently"
fi
if [ -L "$R/repo/agents/probe1/.claude-config/skills" ]; then
  pass "and the link returns as soon as its target is back (the farm self-heals)"
else
  fail "the target came back but the link did not -- the gap in (5) is NOT self-healing"
fi

echo
echo "backup-restore-symlinks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
