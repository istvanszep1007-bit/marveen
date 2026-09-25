#!/usr/bin/env bash
# Marveen backup.
#
# The archive has two top-level groups so a restore is unambiguous about
# where each file belongs (see docs/MIGRATION.md):
#
#   repo/   -> extract under the project root (this repo)
#     store/**                 (DB WAL-checkpointed first; minus models,
#                               virtualenvs, browser profile and logs)
#     .env                     (project root secrets)
#     scheduled-tasks.json     (legacy, if present)
#     assets/meetings/**       (meeting transcripts/memos)
#     agents/**                (the fleet's own work: reports, drafts, research,
#                               held-tests, HANDOFF, memory, skills, identity and
#                               channel secrets; minus the exclusions listed at
#                               the agents/ block below)
#
#   home/   -> extract under $HOME
#     .claude/**                   (exclusion-based since 2026-09-21: the hooks,
#                                  settings.json, skills, scheduled-tasks, the
#                                  file-based memories and everything else that
#                                  is not a transcript, a cache or live process
#                                  state -- see the home/ group below)
#     .claude.json                 (global config: MCP servers, project registry)
#     .claude/channels/*/.env      (MAIN orchestrator channel token)
#     .claude/channels/*/access.json, invites.json, approved/**  (pairing state)
#     Library/LaunchAgents/com.<MAIN_AGENT_ID>.*.plist (launchd jobs)
#
# Output: backups/claudeclaw-YYYYmmdd-HHMMSS.tar.gz
# Retention: keeps the most recent 14 archives, prunes the rest.
#
# Restore (preserve modes so the 0600 token files stay private):
#   tar -xpzf <archive> -C /tmp/restore        # inspect first
#   then copy repo/* into the project root and home/* into $HOME.
# Full runbook: docs/MIGRATION.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so a test can build a throwaway archive without touching the
# real backup directory (and its retention sweep).
BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/claudeclaw-${STAMP}.tar.gz"
# 14 -> 28 (lean-chief jovahagyasa, 2026-09-25): a mentes napi KETSZER fut
# (05:47 es 23:31), tehat 14 archivum mar csak 7 napot fedne. 28 archivum
# ~920 MB a merte 33 MB/archivum mellett, a szabad hely 927 GB.
KEEP=28

mkdir -p "${BACKUP_DIR}"
cd "${REPO_ROOT}"

# Checkpoint WAL into the main DB file so the snapshot is self-contained.
# Tolerate a missing sqlite3 CLI -- just fall back to copying the files as-is.
if [[ -f store/claudeclaw.db ]] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 store/claudeclaw.db 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null || true
fi

# --- Build the two path lists (each relative to its own base). -------------
# tar refuses missing entries, which would fail the whole backup on a fresh
# machine (no agents yet) -- so we only list paths that actually exist.
REPOLIST="$(mktemp -t claudeclaw-repo.XXXXXX)"
HOMELIST="$(mktemp -t claudeclaw-home.XXXXXX)"
MANIFEST="$(mktemp -t claudeclaw-manifest.XXXXXX)"
STAGE="$(mktemp -d -t claudeclaw-stage.XXXXXX)"
BUNDLE=""
trap 'rm -f "${REPOLIST}" "${HOMELIST}" "${MANIFEST}"; [[ -n "${BUNDLE}" ]] && rm -f "${BUNDLE}"; rm -rf "${STAGE}"' EXIT

# add_if <listfile> <base> <relpath>  -- append relpath when <base>/<relpath> exists.
add_if() {
  local list="$1" base="$2" rel="$3"
  if [[ -e "${base}/${rel}" ]]; then echo "${rel}" >> "${list}"; fi
}

# repo/ group (relative to REPO_ROOT)
# store/ -- everything EXCEPT the bulky, regenerable and transient parts.
# Until 2026-09-04 this was a five-name whitelist (the DB, its -shm/-wal, the
# dashboard token, config-overrides.json) and every OTHER file in store/ sat
# outside the archive without ever saying so: the credential vault, the
# verified-recipients ledger that gates every outgoing letter, the egress
# allowlist, the autonomy levels, the per-service API tokens, and hand-made
# data that exists nowhere else (the mail-partner categorisation, the SEO
# baselines, the webshop change log). A whitelist is silent about every file
# added after it was written, so the rule is inverted here: take store/ and
# name only what must stay OUT.
#   whisper, health, cowork, venv-*, dhl-chrome-profile, fedex-labels,
#   fedex-vam, archery-basis  -- models, exports, virtualenvs, a browser
#     profile and generated PDFs: 3.2 GB, all re-downloadable or reproducible
#   *.log, *.out, *.pid       -- runtime noise, worthless in a restore
# What remains is ~4 MB next to the DB, so the archive stays small.
STORE_SKIP=" whisper health cowork venv-garmin venv-pdf dhl-chrome-profile fedex-labels fedex-vam archery-basis "
if [[ -d store ]]; then
  while IFS= read -r _entry; do
    _name="$(basename "${_entry}")"
    case "${STORE_SKIP}" in *" ${_name} "*) continue ;; esac
    case "${_name}" in *.log|*.out|*.pid) continue ;; esac
    echo "store/${_name}" >> "${REPOLIST}"
  done < <(find store -mindepth 1 -maxdepth 1)
fi
add_if "${REPOLIST}" "${REPO_ROOT}" .env
add_if "${REPOLIST}" "${REPO_ROOT}" scheduled-tasks.json
add_if "${REPOLIST}" "${REPO_ROOT}" assets/meetings
# agents/ -- the fleet's OWN WORK, and until 2026-09-21 almost none of it was
# here. The rule above it was a five-name whitelist (CLAUDE.md, SOUL.md,
# .mcp.json, access.json, .env), i.e. identity and secrets only: measured that
# day, 271 files sat under agents/ and the filter carried 23. The other 248 were
# the reports, drafts, research, held-tests and HANDOFF files -- and since the
# THIN CHIEF standard makes the FILE the deliverable and the chat only a header,
# that set IS the team's output. agents/ is gitignored (.gitignore:19), so git
# does not hold it, and a carrier patch carries tracked changes only, so no
# carrier can hold it either. This was the only copy on the machine.
#
# So the same inversion as store/ above: take agents/ and name what stays OUT.
# A whitelist is silent about everything created after it was written, which is
# exactly how 248 files went unbacked for weeks without a single warning.
#
# What stays out, and why (each one measured 2026-09-21):
#   .claude-config/projects/**  session transcripts, 12 files / 25.1 MB, one of
#     them 25 MB on its own and still growing. Regenerated by the runtime, and
#     they would more than double a 22 MB archive. NOTE: the REST of
#     .claude-config (settings.json, .claude.json, plugins, policy stamp -- 35
#     files, 0.4 MB) IS taken: it is the config each agent actually runs with,
#     it differs from .claude/settings.json (measured: 8104 vs 11456 bytes), and
#     dropping the whole directory by name would have repeated this card's bug.
#   avatar.jpg                  7 files / 1.8 MB of decoration, re-creatable.
#   channels/*/inbox/**         received-message spool, runtime and transient --
#     the same call already made for the MAIN agent's channels below.
#   __pycache__, node_modules, .venv  build/dependency output. NONE exist under
#     agents/ today; they are named so they can never arrive silently later.
#   *.log, *.out, *.pid         runtime noise, same rule as store/ above.
#
# find does not follow symlinks, which matters here: every agent's
# .claude-config is a farm of symlinks into ~/.HOME/.claude, and dereferencing
# them would pull the whole global config in seven times over.
if [[ -d agents ]]; then
  find agents -type f \
    ! -path '*/.claude-config/projects/*' \
    ! -path '*/__pycache__/*' \
    ! -path '*/node_modules/*' \
    ! -path '*/.venv/*' \
    ! -path '*/channels/*/inbox/*' \
    ! -name 'avatar.jpg' \
    ! -name '*.log' ! -name '*.out' ! -name '*.pid' \
    -print >> "${REPOLIST}"
fi

# home/ group (relative to $HOME)
# ~/.claude -- the SAME inversion as agents/ above, for the same reason, one
# level up. Until 2026-09-21 this was a whitelist of four names (skills,
# scheduled-tasks, projects/*/memory, and the channel secrets below), and
# measured that day it carried 66 of the 5128 files under ~/.claude. Two of the
# misses could not be replaced from anywhere:
#   .claude/hooks/**      six scripts, and FIVE of the six DIFFER from their
#     namesake in the repo (telegram_progress_watchdog.py: 11353 bytes here vs
#     19975 in the repo). They are not copies of the tracked files, they are the
#     live, drifted versions; git is no fallback for them because they live
#     under $HOME, and no carrier patch reaches outside the repo either.
#   .claude/settings.json 11 matcher blocks over seven hook events (PreCompact,
#     SessionStart, PostToolUse, UserPromptSubmit, PreToolUse, Stop, SessionEnd).
#     A script can be rewritten from memory; which EVENT it was wired to cannot
#     be guessed back.
# So: take ~/.claude and name only what stays OUT. Each exclusion measured
# 2026-09-21 on this host, file counts and sizes from the live tree.
#   projects/**            465 files / 190.9 MB of session transcripts -- eight
#     times the whole archive. The memory/ directories inside it are taken back
#     by the dedicated rule below; that split is the point, not an oversight.
#   plugins/cache/**       3620 files / 16.5 MB, and
#   plugins/marketplaces/** 490 files / 8.8 MB -- a git clone of the official
#     marketplace, re-fetchable. installed_plugins.json (813 b) and
#     known_marketplaces.json (276 b) are NOT excluded: they record WHICH
#     plugins and WHICH marketplaces, which is the part nothing can re-derive.
#   file-history/**        429 files / 4.9 MB of per-edit undo state.
#   history.jsonl          2.6 MB prompt transcript, same class as projects/**.
#   cache/**, paste-cache/**, tmp/**, downloads/**  regenerable or transient.
#   shell-snapshots/**     runtime captures, meaningless after a restore.
#   sessions/**, session-env/**  LIVE process state: pid, procStart, cwd. Not
#     stale after a restore, actively wrong.
#   statsig/**, ide/**     telemetry and editor-bridge state. NEITHER EXISTS on
#     this host today; they are named so they cannot arrive silently later.
#   channels/**            excluded HERE only because the dedicated rule below
#     takes the parts that matter (secrets, pairing state) and leaves the inbox
#     spool and bot.pid out. Dropping this exclusion would double-add them.
#   *.log, *.out, *.pid    runtime noise, same rule as store/ and agents/.
# There are no symlinks in the kept area (measured: 0), so a file-only list
# loses nothing, and every empty directory left behind sits inside an excluded
# tree (downloads, channels, session-env).
if [[ -d "${HOME}/.claude" ]]; then
  ( cd "${HOME}" && find .claude -type f \
      ! -path '.claude/projects/*' \
      ! -path '.claude/plugins/cache/*' \
      ! -path '.claude/plugins/marketplaces/*' \
      ! -path '.claude/cache/*' \
      ! -path '.claude/paste-cache/*' \
      ! -path '.claude/file-history/*' \
      ! -path '.claude/shell-snapshots/*' \
      ! -path '.claude/sessions/*' \
      ! -path '.claude/session-env/*' \
      ! -path '.claude/downloads/*' \
      ! -path '.claude/tmp/*' \
      ! -path '.claude/statsig/*' \
      ! -path '.claude/ide/*' \
      ! -path '.claude/channels/*' \
      ! -name 'history.jsonl' \
      ! -name '*.log' ! -name '*.out' ! -name '*.pid' \
      -print ) >> "${HOMELIST}"
fi
# ~/.claude.json -- the global Claude Code config (47 kB on this host: the MCP
# server definitions, the project registry, the account binding). It sits NEXT
# TO ~/.claude, not inside it, so the find above cannot reach it, and measured
# 2026-09-21 it was in no archive at all. Its own rolling backups already come
# along inside .claude/backups/, which made the original missing without ever
# looking missing.
add_if "${HOMELIST}" "${HOME}" .claude.json
# The file-based auto-memory. Until 2026-09-04 this was NOT in the archive, and
# a restore test that day proved what that costs: 490 markdown memories for the
# main agent alone, none of them in the tarball. The SQLite copy is not a
# substitute -- it holds the prose, not the frontmatter, the type or the
# [[links]] between memories. Only the memory/ directories are taken, not the
# whole projects/ tree, which is full of transcripts and tool-result dumps.
if [[ -d "${HOME}/.claude/projects" ]]; then
  ( cd "${HOME}" && find .claude/projects -maxdepth 2 -type d -name memory -print ) >> "${HOMELIST}"
fi
# MAIN orchestrator channel tokens + pairing state, per provider. bot.pid and
# inbox/ are runtime/transient and intentionally excluded. Since #915 the
# main state dir is install-scoped (<repo>/.claude/channels/<provider>); the
# HOME base only still holds it on an unmigrated install -- take both, each
# from its own list so restore puts them back where they came from.
if [[ -d "${HOME}/.claude/channels" ]]; then
  ( cd "${HOME}" && find .claude/channels -maxdepth 2 \
      \( -name '.env' -o -name 'access.json' -o -name 'invites.json' \) \
      -print ) >> "${HOMELIST}"
  ( cd "${HOME}" && find .claude/channels -maxdepth 2 -type d -name 'approved' -print ) >> "${HOMELIST}"
fi
if [[ -d "${REPO_ROOT}/.claude/channels" ]]; then
  ( cd "${REPO_ROOT}" && find .claude/channels -maxdepth 2 \
      \( -name '.env' -o -name 'access.json' -o -name 'invites.json' \) \
      -print ) >> "${REPOLIST}"
  ( cd "${REPO_ROOT}" && find .claude/channels -maxdepth 2 -type d -name 'approved' -print ) >> "${REPOLIST}"
fi
# launchd jobs for this fleet. The job labels are com.<MAIN_AGENT_ID>.<service>
# (see src/web/main-agent.ts), so resolve MAIN_AGENT_ID the way the app does
# (src/env.ts: read from .env, default "marveen" when unset) instead of
# hardcoding one deployment's prefix. Parsing mirrors env.ts: last definition
# wins, surrounding matching quotes stripped.
MAIN_AGENT_ID="marveen"
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # `|| true`: with `set -o pipefail`, a no-match grep would otherwise fail the
  # whole substitution (and, under `set -e`, abort the backup) on any install
  # that leaves MAIN_AGENT_ID unset and relies on the "marveen" default.
  _mid="$(grep -E '^[[:space:]]*MAIN_AGENT_ID[[:space:]]*=' "${REPO_ROOT}/.env" | tail -1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' || true)"
  [[ -n "${_mid}" ]] && MAIN_AGENT_ID="${_mid}"
fi
if [[ -d "${HOME}/Library/LaunchAgents" ]]; then
  ( cd "${HOME}" && find Library/LaunchAgents -maxdepth 1 -name "com.${MAIN_AGENT_ID}.*.plist" -print ) >> "${HOMELIST}"
fi

# --- Local commits that live on no remote. ---------------------------------
# This archive deliberately carries unversioned state, not the source: the
# source is supposed to live on a git remote. On 2026-09-04 that assumption
# broke -- nine days of work sat committed locally and pushed nowhere, so the
# only copy was this disk, and the tarball did not hold it either. A bundle of
# every local branch that origin does not already have closes the gap for a few
# hundred KB (the full history is 26 MB, but the shared part is recoverable by
# cloning origin). Restore, after cloning origin:
#   git fetch <restored>/repo/local-commits.bundle 'refs/heads/*:refs/heads/*'
if command -v git >/dev/null 2>&1 && [[ -d "${REPO_ROOT}/.git" ]]; then
  BUNDLE="$(mktemp -t claudeclaw-bundle.XXXXXX)"
  # An empty ref set makes `git bundle` refuse with "empty bundle", which is
  # the GOOD case (everything is already pushed), not an error -- so a failure
  # here just drops the file instead of failing the backup.
  if git -C "${REPO_ROOT}" bundle create "${BUNDLE}" \
       --branches --not --remotes=origin >/dev/null 2>&1; then
    echo "backup: local-commits.bundle $(wc -c < "${BUNDLE}" | awk '{print $1}') bytes"
  else
    rm -f "${BUNDLE}"; BUNDLE=""
    echo "backup: no local-only commits to bundle"
  fi
fi

if [[ ! -s "${REPOLIST}" && ! -s "${HOMELIST}" ]]; then
  echo "backup: nothing to archive" >&2
  exit 0
fi

# --- Manifest (stored at the archive root for self-description). -----------
{
  echo "Marveen backup ${STAMP}"
  echo "host: $(hostname 2>/dev/null || echo '?')   user: ${USER:-?}   home: ${HOME}"
  echo "repo root: ${REPO_ROOT}"
  echo "Restore: tar -xpzf <archive> -C <tmp>; copy repo/* -> project root, home/* -> \$HOME."
  echo "See docs/MIGRATION.md for the full runbook (TCC, launchd paths, one-bot-one-poller, venv rebuild)."
  echo "--- repo/ ---"; sed 's,^,repo/,' "${REPOLIST}" 2>/dev/null || true
  if [[ -n "${BUNDLE}" ]]; then
    echo "repo/local-commits.bundle   (git bundle: local branches absent from origin)"
  fi
  echo "--- home/ ---"; sed 's,^,home/,' "${HOMELIST}" 2>/dev/null || true
} > "${MANIFEST}"

# --- Assemble the archive via a staging dir, then one plain tar. -----------
# The repo/ and home/ groups are produced by copying into a staging tree, NOT
# by tar name-substitution: bsdtar's `-s` and GNU tar's `--transform` are
# mutually incompatible (on GNU tar, `-s` is `--same-order` and takes no
# argument), so a substitution-based build is not portable. Staging + a single
# `tar -czf -C "${STAGE}" .` works identically on macOS (bsdtar) and Linux
# (GNU tar). Everything backed up is small (a few MB), so the copy is cheap;
# `cp -pR` preserves modes so the 0600 token files stay private.
cp "${MANIFEST}" "${STAGE}/MANIFEST.txt"

stage_group() {  # stage_group <listfile> <base> <group>
  local list="$1" base="$2" group="$3" rel parent
  [[ -s "${list}" ]] || return 0
  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    parent="$(dirname "${rel}")"
    mkdir -p "${STAGE}/${group}/${parent}"
    cp -pR "${base}/${rel}" "${STAGE}/${group}/${parent}/"
  done < "${list}"
}

stage_group "${REPOLIST}" "${REPO_ROOT}" repo
stage_group "${HOMELIST}" "${HOME}" home

if [[ -n "${BUNDLE}" ]]; then
  mkdir -p "${STAGE}/repo"
  cp -p "${BUNDLE}" "${STAGE}/repo/local-commits.bundle"
  chmod 600 "${STAGE}/repo/local-commits.bundle"
fi

# Archive only the top-level entries that exist (a group dir is absent when
# its list was empty), so tar never errors on a missing entry and the names
# stay clean (no leading "./").
( cd "${STAGE}" && tar -czf "${ARCHIVE}" MANIFEST.txt \
    $( [[ -d repo ]] && echo repo ) $( [[ -d home ]] && echo home ) )
echo "backup: wrote ${ARCHIVE} ($(wc -c < "${ARCHIVE}" | awk '{print $1}') bytes)"

# --- Verify the archive against the manifest. ------------------------------
# The manifest says what the backup INTENDED to carry; until now nothing
# checked what it actually carries. That gap is exactly how 2026-09-04
# happened: the store/ whitelist had been silently dropping files for weeks
# and the restore test was what finally noticed, not the backup itself. A
# backup that cannot say what is inside it is a promise, not a copy.
#
# Two checks, because they fail differently:
#   - every manifest entry has a matching path in the archive (a staging copy
#     that silently did nothing shows up here),
#   - a few load-bearing items are present by name (an archive that is valid,
#     small and useless -- the 09-04 shape -- shows up here even if the
#     manifest itself was built wrong).
ARCHIVE_LIST="$(mktemp -t claudeclaw-verify.XXXXXX)"
trap 'rm -f "${REPOLIST}" "${HOMELIST}" "${MANIFEST}" "${ARCHIVE_LIST}"; [[ -n "${BUNDLE}" ]] && rm -f "${BUNDLE}"; rm -rf "${STAGE}"' EXIT
tar -tzf "${ARCHIVE}" > "${ARCHIVE_LIST}"

missing=0
while IFS= read -r want; do
  # Manifest body lines only: the header block and the group separators are
  # prose, not paths.
  case "${want}" in repo/*|home/*) ;; *) continue ;; esac
  # A directory entry is listed once in the manifest and expands to many paths
  # in the archive, so match on the prefix, and anchor it so "store/x" cannot
  # be satisfied by "store/xyz".
  if ! grep -qE "^${want}(/|$)" "${ARCHIVE_LIST}"; then
    echo "backup: MISSING from the archive: ${want}" >&2
    missing=$((missing + 1))
  fi
done < <(sed -e 's/  *(.*)$//' "${MANIFEST}")

# Load-bearing by name. Each one has already been lost or nearly lost once:
# the memory directories and the local-commit bundle on 2026-09-04, the
# credential-carrying store/ files by the whitelist that preceded it.
for marker in "repo/store/claudeclaw.db" "home/.claude/skills" "home/.claude/scheduled-tasks"; do
  grep -qE "^${marker}(/|$)" "${ARCHIVE_LIST}" || {
    echo "backup: MISSING load-bearing item: ${marker}" >&2
    missing=$((missing + 1))
  }
done
# 2026-09-21 (f213320b): claudeclaw.db-wal. The marker above names the DB, which
# reads as "the database is protected" -- and it is not. The WAL checkpoint at the
# top of this script is guarded by `command -v sqlite3`, the sqlite3 CLI is not
# installed here and is not an installer dependency, so the checkpoint never runs
# and the newest rows live ONLY in the -wal. Measured that day on the real store:
# restoring without it gives a database that opens, reports integrity_check = ok,
# and holds 364/72/803 rows instead of 369/74/808. Five memories, two cards and
# five messages, lost without a single word anywhere. Existence-guarded, because a
# host that DOES have sqlite3 checkpoints the WAL away and has nothing to carry.
if [[ -f "${REPO_ROOT}/store/claudeclaw.db-wal" ]]; then
  grep -qxF "repo/store/claudeclaw.db-wal" "${ARCHIVE_LIST}" || {
    echo "backup: MISSING load-bearing item: repo/store/claudeclaw.db-wal" >&2
    echo "backup:   (the DB would restore as valid-but-short; there is no sqlite3 here to checkpoint it)" >&2
    missing=$((missing + 1))
  }
fi

# 2026-09-21 (bac15cf9): the two $HOME items this card was about are load-bearing
# in the strict sense. Five of the six hook scripts differ from their repo
# namesakes, and settings.json is the only record of WHICH event each hook is
# wired to; neither is recoverable from git, so a silent drop must fail the
# backup rather than produce a green one. Each is guarded by existence, so a
# fresh install that has neither still passes its first backup.
if [[ -e "${HOME}/.claude/hooks" ]]; then
  grep -qE "^home/\.claude/hooks(/|$)" "${ARCHIVE_LIST}" || {
    echo "backup: MISSING load-bearing item: home/.claude/hooks" >&2
    missing=$((missing + 1))
  }
fi
if [[ -e "${HOME}/.claude/settings.json" ]]; then
  grep -qE "^home/\.claude/settings\.json$" "${ARCHIVE_LIST}" || {
    echo "backup: MISSING load-bearing item: home/.claude/settings.json" >&2
    missing=$((missing + 1))
  }
fi

# The file-based memories: only required when this host actually has some, so
# a fresh install does not fail its first backup.
if ( cd "${HOME}" && find .claude/projects -maxdepth 2 -type d -name memory -print -quit 2>/dev/null | grep -q . ); then
  grep -qE "^home/\.claude/projects/.*/memory(/|$)" "${ARCHIVE_LIST}" || {
    echo "backup: MISSING load-bearing item: the file-based memory directories" >&2
    missing=$((missing + 1))
  }
fi

if [[ "${missing}" -gt 0 ]]; then
  echo "backup: FAILED verification -- ${missing} item(s) named in the manifest are not in ${ARCHIVE}." >&2
  echo "backup: the archive is kept for inspection, but do NOT treat it as a good copy." >&2
  # launchd sends this script's output to logs/backup.log, which nobody opens.
  # A loud failure into an unread file is the same silence the verification
  # above exists to break, so the failure also goes onto the agent message
  # queue, where it survives the agent being asleep at 04:30 and gets read on
  # the next turn. Best-effort: a messaging problem must not change the exit
  # code or mask the real failure.
  if [[ -x "${REPO_ROOT}/scripts/agent-msg.sh" ]]; then
    bash "${REPO_ROOT}/scripts/agent-msg.sh" halpali halpali \
      "[MENTES] A napi mentes ellenorzese ELBUKOTT ${STAMP}-kor: ${missing} tetel hianyzik az archivumbol (reszletek: logs/backup.log). Az archivum NEM tekintheto jo masolatnak." \
      >/dev/null 2>&1 || true
  fi
  exit 6
fi
echo "backup: verified $(grep -cE '^(repo|home)/' "${MANIFEST}") manifest entries against the archive"

# The archive contains sensitive tokens (dashboard bearer, channel bot tokens,
# project .env secrets). Do not auto-sync ${BACKUP_DIR} to iCloud, Dropbox,
# Google Drive, or any other cloud-backup folder. Keep it local.
echo "backup: WARNING -- archive contains sensitive tokens; keep ${BACKUP_DIR} out of cloud-sync folders (iCloud / Dropbox / Google Drive)." >&2

# Keep the newest ${KEEP} archives, drop the rest. while-read (not mapfile)
# for macOS bash 3.2 compatibility.
ls -1t "${BACKUP_DIR}"/claudeclaw-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r f; do
  [[ -z "${f}" ]] && continue
  rm -f "${f}"
  echo "backup: pruned $(basename "${f}")"
done
