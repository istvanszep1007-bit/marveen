// Reap orphaned channel-plugin pollers (bun/node processes that survived a
// tmux kill-session or are left over from a previous agent crash).
//
// The bug we close (2026-06-01 incident, channel-disconnect roundtrip):
//   - stopAgentProcess used `pkill -f TELEGRAM_STATE_DIR=<dir>`, but the
//     plugin process argv is just `bun run --cwd .../telegram/0.0.6 start`
//     - the env var lives in /proc-equivalent environment storage, not argv,
//     so `pkill -f` never matches and the orphan keeps polling getUpdates
//     with the same bot token until SIGTERM by hand.
//   - startAgentProcess only killed the tmux session pre-launch and did NOT
//     reap orphans at all. After a restart the old poller raced the new one
//     and Telegram returned 409 Conflict in a loop.
//   - The plugin writes bot.pid in <chanDir>/bot.pid. That works on the
//     happy path but if a new poller crashed and a later one overwrote the
//     file, the older orphan is no longer in bot.pid - we miss it.
//
// Strategy: combine two identifiers.
//   1. bot.pid (cheap, works for the supervised process).
//   2. `ps eww -e` scan for the *_STATE_DIR=<chanDir> env-var match. This
//      catches orphans whose pid is no longer in bot.pid - any process that
//      was started against this channel state dir is in scope, regardless
//      of how its argv was rendered. macOS BSD ps emits each process's full
//      environment when invoked with `e`; we grep that.

import { execFileSync, execSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { ChannelProviderType } from '../channel-provider.js'
import { channelStateDir } from '../channel-provider.js'
import { logger } from '../logger.js'

const STATE_ENV_VAR: Record<ChannelProviderType, string> = {
  telegram: 'TELEGRAM_STATE_DIR',
  slack: 'SLACK_STATE_DIR',
  discord: 'DISCORD_STATE_DIR',
  googlechat: 'GOOGLECHAT_STATE_DIR',
  teams: 'TEAMS_STATE_DIR',
}

// Parse `ps eww -e` output and return every PID whose process environment
// contains `<envVar>=<value>`. Exported for testability.
//
// `ps eww -e` rows on macOS look like:
//   90798 s000  S+   0:00.01 bun run --cwd ... HOME=/Users/... TELEGRAM_STATE_DIR=/path... ...
// The match must be precise: substring `TELEGRAM_STATE_DIR=/path` against
// `TELEGRAM_STATE_DIR=/path-elsewhere` is acceptable because the value is an
// absolute path, but we still anchor on the env-var literal to avoid
// matching a row that just *mentions* the path string in its argv.
export function parsePollerPidsFromPs(
  psOutput: string,
  envVar: string,
  value: string,
): number[] {
  const needle = `${envVar}=${value}`
  const out: number[] = []
  for (const line of psOutput.split('\n')) {
    if (!line.includes(needle)) continue
    const m = line.match(/^\s*(\d+)\s/)
    if (!m) continue
    const pid = parseInt(m[1]!, 10)
    if (pid > 1) out.push(pid)
  }
  return out
}

function listPollerPidsByStateDir(envVar: string, chanDir: string): number[] {
  try {
    const out = execSync('/bin/ps eww -e', { timeout: 5000, encoding: 'utf-8', maxBuffer: 8 * 1024 * 1024 })
    return parsePollerPidsFromPs(out, envVar, chanDir)
  } catch (err) {
    logger.warn({ err, chanDir }, 'channel-poller-reap: ps scan failed')
    return []
  }
}

function readBotPid(chanDir: string): number | null {
  const path = join(chanDir, 'bot.pid')
  if (!existsSync(path)) return null
  try {
    const pid = parseInt(readFileSync(path, 'utf-8').trim(), 10)
    return Number.isFinite(pid) && pid > 1 ? pid : null
  } catch {
    return null
  }
}

export interface ReapResult {
  reaped: number[]
  source: { fromBotPid: number | null; fromEnvScan: number[] }
}

// ---------------------------------------------------------------------------
// Down-verdict forensics (2026-07-14).
//
// The watchdog restarted agents ~10x/day on a "channel plugin down" verdict,
// and the restart DESTROYS the evidence: the poller is reaped, the session is
// respawned, and the post-mortem log says only "down -- auto-restarting". So
// the interesting question -- did the poller really die, or did the tree-walk
// lose a live one? -- could not be answered from the logs at all.
//
// This captures the state at the MOMENT the verdict is formed, before anything
// is torn down: is a poller process for this chanDir alive at all, is it in the
// claude process tree, and does bot.pid still point at it. One WARN per
// down-spell, so it costs a ps per spell, not per sweep.

export interface PollerEvidenceRow {
  pid: number
  ppid: number
  // Whether claudePid is an ancestor of this pid. FALSE with a live pid is the
  // interesting case: the poller exists but hangs outside the tree the liveness
  // probe walks (reparented / attached to a previous claude).
  inClaudeTree: boolean
}

export interface PollerEvidence {
  botPid: number | null
  botPidAlive: boolean
  // Pollers found by env-var scan, i.e. every process started against this
  // channel state dir regardless of parentage.
  envScanPids: number[]
  rows: PollerEvidenceRow[]
  // The verdict this evidence supports, spelled out so the log line is readable
  // without re-deriving it:
  //   'no-poller'      -> nothing alive: the plugin really did die.
  //   'orphaned'       -> a live poller exists but is NOT under claude.
  //   'in-tree'        -> a live poller IS under claude: the probe was WRONG.
  interpretation: 'no-poller' | 'orphaned' | 'in-tree'
}

// Pure core: exported for tests (no ps, no fs).
export function buildPollerEvidence(
  procs: ProcRow[],
  botPid: number | null,
  envScanPids: number[],
  claudePid: number,
): PollerEvidence {
  const byPid = new Map<number, ProcRow>()
  for (const p of procs) byPid.set(p.pid, p)

  const isUnderClaude = (pid: number): boolean => {
    let cur = pid
    const seen = new Set<number>()
    for (let hops = 0; hops < 8; hops++) {
      if (cur === claudePid) return true
      if (seen.has(cur)) break
      seen.add(cur)
      const next = byPid.get(cur)?.ppid
      if (next === undefined || next === cur || next <= 1) break
      cur = next
    }
    return false
  }

  const candidates = new Set<number>(envScanPids)
  if (botPid != null) candidates.add(botPid)

  const rows: PollerEvidenceRow[] = []
  for (const pid of candidates) {
    const row = byPid.get(pid)
    if (!row) continue // not in the ps snapshot -> dead
    rows.push({ pid, ppid: row.ppid, inClaudeTree: isUnderClaude(pid) })
  }

  const interpretation: PollerEvidence['interpretation'] = rows.length === 0
    ? 'no-poller'
    : rows.some((r) => r.inClaudeTree) ? 'in-tree' : 'orphaned'

  return {
    botPid,
    botPidAlive: botPid != null && byPid.has(botPid),
    envScanPids,
    rows,
    interpretation,
  }
}

// Collect the evidence for one agent. Call this ONCE per down-spell, at the
// first down observation, BEFORE any teardown.
export function collectPollerEvidence(
  provider: ChannelProviderType,
  agentDirPath: string,
  claudePid: number,
): PollerEvidence {
  const chanDir = channelStateDir(provider, agentDirPath)
  return buildPollerEvidence(
    snapshotProcs(),
    readBotPid(chanDir),
    listPollerPidsByStateDir(STATE_ENV_VAR[provider], chanDir),
    claudePid,
  )
}

/**
 * Reap every channel-plugin poller process associated with this agent.
 * Combines bot.pid (cheap, supervised pid) with a `ps eww -e` env-var scan
 * (catches orphans whose pid is no longer in bot.pid). SIGTERM first; after
 * a short grace period, SIGKILL any survivor. Safe to call multiple times
 * (process.kill on a missing pid is caught).
 */
// ---------------------------------------------------------------------------
// WHO IS ACTUALLY A POLLER (2026-09-21, card ee485f5e).
//
// The env-var scan above answers "which processes were started against this
// channel state dir". For years that was the same set as "which processes are
// the plugin poller", because channels.sh launched the MAIN session withOUT
// exporting *_STATE_DIR -- a fact the comments in this file and in
// channel-monitor.ts still asserted. #915 changed it: channels.sh now exports
// the var (see scripts/channels.sh, "the plugin honours *_STATE_DIR, and with
// it exported the main session's poller does carry it"), and env vars are
// INHERITED. So the needle now also matches:
//   * the session's own `claude` process -- which on the main session IS the
//     tmux pane leader, so SIGTERMing it destroys the session, and
//   * every unrelated child that happened to inherit it, down to the watchdog's
//     own `sleep 5` inside scripts/channels.sh.
//
// Measured on this host 2026-09-21 06:55 (5 matches for one channel dir):
//   641057 claude  <- tmux pane pid of lean-chief-channels
//   641186 bun     <- plugin launcher      }  the only real pollers
//   641196 bun     <- bot.pid              }
//   668857 sleep   <- child of channels.sh (the watchdog's own sleep)
// and in the outage (03:00-06:31) the reaper killed all four of them, 40 times,
// every attempt taking the bridge down for the next 4-6 minutes.
//
// So the candidate list is now a SUPERSET of the pollers and must be filtered.
// Three independent guards, because the expensive failure is killing the
// session and the cheap failure is leaving one orphan for the next sweep:
//   1. pane        -- the pid IS a live tmux pane pid. Never killable here:
//                     that is an agent session, not a poller.
//   2. pane-ancestor -- an ancestor of a live pane (the tmux server, systemd).
//   3. claude      -- argv[0] basename is `claude`. An agent process, whatever
//                     its parentage; DETACHED ones are reapDetachedChannelClaudes'
//                     job, and that function identifies them by pane attribution
//                     instead of env/argv heuristics (see its comment).
//   4. not-a-runtime -- argv[0] basename is not a JS runtime. A channel plugin
//                     poller is always run by one (`bun run ...`, `node
//                     server.ts`); a `sleep`/`git`/`npm install` that merely
//                     inherited the env var is not. Applied to ENV-SCAN
//                     candidates only: bot.pid is written by the plugin itself,
//                     so a poller shipped as a compiled binary is still reaped
//                     through that path. The gap this leaves is narrow and
//                     named: a NON-JS orphan whose pid is no longer in bot.pid.
//
// The pollers themselves are descendants of the pane and are still reaped --
// that is the whole point of reaping BEFORE a respawn (a surviving poller
// 409-races the new one). Only the pane itself and its ancestors are spared.
const POLLER_RUNTIMES = new Set(['bun', 'bunx', 'node', 'nodejs', 'deno', 'npm', 'npx'])

function argv0Base(command: string): string {
  const argv0 = command.trim().split(/\s+/, 1)[0] ?? ''
  return argv0.split('/').pop() ?? ''
}

export interface PollerSelection {
  reap: number[]
  spared: { pid: number; reason: 'pane' | 'pane-ancestor' | 'claude' | 'not-a-runtime' | 'gone' }[]
}

/**
 * Pure: split reap candidates into "actually a poller" and "spared, with a
 * reason". `fromBotPid` is exempt from the runtime check (see guard 4 above).
 * Exported for testability -- no ps, no tmux, no kill.
 */
export function selectReapablePollers(
  candidates: number[],
  procs: ProcRow[],
  panePids: Set<number>,
  fromBotPid: number | null,
): PollerSelection {
  const byPid = new Map<number, ProcRow>()
  for (const p of procs) byPid.set(p.pid, p)

  // Every ancestor of every live pane, walked once.
  const paneAncestors = new Set<number>()
  for (const pane of panePids) {
    let cur = byPid.get(pane)?.ppid
    const seen = new Set<number>()
    for (let hops = 0; hops < 16 && cur !== undefined && cur > 1; hops++) {
      if (seen.has(cur)) break
      seen.add(cur)
      paneAncestors.add(cur)
      cur = byPid.get(cur)?.ppid
    }
  }

  const reap: number[] = []
  const spared: PollerSelection['spared'] = []
  for (const pid of candidates) {
    const row = byPid.get(pid)
    if (!row) { spared.push({ pid, reason: 'gone' }); continue }
    if (panePids.has(pid)) { spared.push({ pid, reason: 'pane' }); continue }
    if (paneAncestors.has(pid)) { spared.push({ pid, reason: 'pane-ancestor' }); continue }
    if (argv0Base(row.command) === 'claude') { spared.push({ pid, reason: 'claude' }); continue }
    if (pid !== fromBotPid && !POLLER_RUNTIMES.has(argv0Base(row.command))) {
      spared.push({ pid, reason: 'not-a-runtime' }); continue
    }
    reap.push(pid)
  }
  return { reap, spared }
}

export function reapChannelOrphans(
  provider: ChannelProviderType,
  agentDirPath: string,
  opts: { tmuxPath?: string } = {},
): ReapResult {
  const chanDir = channelStateDir(provider, agentDirPath)
  const envVar = STATE_ENV_VAR[provider]

  const fromBotPid = readBotPid(chanDir)
  const fromEnvScan = listPollerPidsByStateDir(envVar, chanDir)

  // Deduplicate while preserving order so the bot.pid path is logged first.
  const candidates: number[] = []
  const seen = new Set<number>()
  for (const pid of [fromBotPid, ...fromEnvScan]) {
    if (pid && !seen.has(pid)) {
      seen.add(pid)
      candidates.push(pid)
    }
  }

  // FAIL SAFE, same precedent as reapDetachedChannelClaudes below: without a
  // process snapshot we cannot tell the poller from the pane, and the wrong
  // guess costs the whole channel. An un-reaped orphan costs one 409-racing
  // sweep. Refuse rather than kill blind.
  const procs = candidates.length > 0 ? snapshotProcs() : []
  if (candidates.length > 0 && procs.length === 0) {
    logger.warn({ provider, chanDir, candidates }, 'channel-poller-reap: ps snapshot unavailable, skipping reap (fail-safe)')
    return { reaped: [], source: { fromBotPid, fromEnvScan } }
  }
  const panePids = candidates.length > 0 ? livePanePids(opts.tmuxPath ?? 'tmux') : new Set<number>()
  const selection = selectReapablePollers(candidates, procs, panePids, fromBotPid)
  const all = selection.reap
  if (selection.spared.length > 0) {
    logger.info({ provider, chanDir, spared: selection.spared }, 'channel-poller-reap: candidates spared (not pollers)')
  }

  // SIGTERM, give bun/node ~300ms to flush, then SIGKILL stragglers.
  for (const pid of all) {
    try { process.kill(pid, 'SIGTERM') } catch { /* already gone */ }
  }
  if (all.length > 0) {
    try { execFileSync('/bin/sleep', ['0.3'], { timeout: 2000 }) } catch { /* ignore */ }
    for (const pid of all) {
      try { process.kill(pid, 0) /* probe */; process.kill(pid, 'SIGKILL') } catch { /* gone */ }
    }
  }

  if (all.length > 0) {
    logger.info({ provider, chanDir, reaped: all, fromBotPid, fromEnvScan }, 'channel-poller-reap: orphans killed')
  }
  return { reaped: all, source: { fromBotPid, fromEnvScan } }
}

// ---------------------------------------------------------------------------
// Detached channel CLAUDE reaper (the parent-process leak, 2026-06-03).
//
// reapChannelOrphans (above) kills bun/node POLLERS by env-var scan + bot.pid.
//
// CORRECTED 2026-09-21 (card ee485f5e): the paragraph that stood here claimed
// the env scan "MISSES the main channels session entirely", because channels.sh
// launched the main `claude --channels` with no *_STATE_DIR export. That has
// been false since #915 -- channels.sh exports it, the plugin writes bot.pid,
// and the main claude and its bun poller BOTH match the needle. The claim was
// load-bearing: it was the reason reapChannelOrphans had no pane guard, and
// once it went stale the reaper started SIGTERMing the main session's own
// pane leader (measured: 40 times between 03:00 and 06:31 on 2026-09-21).
// reapChannelOrphans now filters its candidates (selectReapablePollers).
//
// What this function is still for: a detached `claude --channels` left behind by
// a --continue respawn. When a --continue respawn (channel-monitor
// respawn-pane / agent-process start) fails to tear down the prior claude, the
// detached claude survives -- reparented to the tmux server -- and keeps a bun
// poller hitting getUpdates on the SHARED bot token. 5 such orphans accumulated
// over 13 days, each 409-racing the live poller (token churn + a self-feeding
// agent thrash-restart loop). See project_channels_continue_respawn_leak.
//
// Identification is by tmux-pane attribution, NOT env/argv heuristics (cmdline
// alone cannot tell a live agent claude from a detached one -- see
// feedback_verify_session_before_kill): a `claude --channels` process is an
// orphan iff neither its pid nor any ancestor pid is a LIVE tmux pane pid.
//   - main session: tmux runs claude as the pane leader, so claudePid == panePid.
//   - sub-agents:   tmux runs `sh -c "...claude..."`, so the pane pid is the sh
//                   and claude is its child -> ancestor walk catches it.
// The tmux SERVER process is excluded up front: its argv embeds the full
// `new-session ... claude --channels ...` string, a false positive, but argv[0]
// is tmux, not claude.

export interface ProcRow { pid: number; ppid: number; command: string }

// argv[0] basename === 'claude' (the binary), so the tmux server row whose argv
// merely *contains* the claude command string is excluded.
function isClaudeBinary(command: string): boolean {
  const argv0 = command.trim().split(/\s+/, 1)[0] ?? ''
  const base = argv0.split('/').pop() ?? ''
  return base === 'claude'
}

/**
 * Pure: return the pids of `claude --channels` processes that are NOT attached
 * to any live tmux pane (orphans). `livePanePids` is the set of pane pids from
 * `tmux list-panes -a`. `channelNeedle` optionally restricts to one plugin
 * (e.g. 'plugin:telegram@...'); when omitted, every channel plugin is in scope.
 * Exported for testability.
 */
export function findOrphanChannelClaudes(
  procs: ProcRow[],
  livePanePids: Set<number>,
  channelNeedle?: string,
): number[] {
  const byPid = new Map<number, ProcRow>()
  for (const p of procs) byPid.set(p.pid, p)

  const attachedToLivePane = (pid: number): boolean => {
    let cur = pid
    const seen = new Set<number>()
    for (let hops = 0; hops < 8; hops++) {
      if (livePanePids.has(cur)) return true
      if (seen.has(cur)) break
      seen.add(cur)
      const next = byPid.get(cur)?.ppid
      if (next === undefined || next === cur || next <= 1) break
      cur = next
    }
    return false
  }

  const orphans: number[] = []
  for (const p of procs) {
    if (!p.command.includes('--channels')) continue
    if (!isClaudeBinary(p.command)) continue
    if (channelNeedle && !p.command.includes(channelNeedle)) continue
    if (attachedToLivePane(p.pid)) continue
    orphans.push(p.pid)
  }
  return orphans
}

function snapshotProcs(): ProcRow[] {
  try {
    const out = execSync('/bin/ps -axww -o pid=,ppid=,command=', { timeout: 5000, encoding: 'utf-8', maxBuffer: 8 * 1024 * 1024 })
    const rows: ProcRow[] = []
    for (const line of out.split('\n')) {
      const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)
      if (!m) continue
      rows.push({ pid: parseInt(m[1]!, 10), ppid: parseInt(m[2]!, 10), command: m[3]! })
    }
    return rows
  } catch (err) {
    logger.warn({ err }, 'channel-poller-reap: ps -axww snapshot failed')
    return []
  }
}

function livePanePids(tmuxPath: string): Set<number> {
  try {
    const out = execSync(`${tmuxPath} list-panes -a -F '#{pane_pid}'`, { timeout: 5000, encoding: 'utf-8' })
    const s = new Set<number>()
    for (const line of out.split('\n')) {
      const n = parseInt(line.trim(), 10)
      if (Number.isFinite(n) && n > 1) s.add(n)
    }
    return s
  } catch (err) {
    logger.warn({ err }, 'channel-poller-reap: tmux list-panes failed')
    return new Set()
  }
}

function killBunChildren(claudePid: number): void {
  try {
    const out = execSync(`/usr/bin/pgrep -P ${claudePid} bun`, { timeout: 3000, encoding: 'utf-8' })
    for (const line of out.split('\n')) {
      const pid = parseInt(line.trim(), 10)
      if (Number.isFinite(pid) && pid > 1) {
        try { process.kill(pid, 'SIGTERM') } catch { /* gone */ }
      }
    }
  } catch { /* no bun children (pgrep exits 1) */ }
}

/**
 * Reap detached `claude --channels` orphans (parent-process leak). SAFE to call
 * before any (re)spawn: it spares every claude attached to a live tmux pane, so
 * it never kills the active session or a live sibling agent -- only truly
 * detached leftovers. Kills each orphan's bun poller children first, then the
 * claude (SIGTERM, ~300ms grace, SIGKILL stragglers). Returns reaped pids.
 *
 * tmuxPath defaults to a bare `tmux` (resolved on PATH); callers that already
 * hold an absolute path should pass it.
 */
export function reapDetachedChannelClaudes(opts: { channelNeedle?: string; tmuxPath?: string } = {}): number[] {
  const tmuxPath = opts.tmuxPath ?? 'tmux'
  const procs = snapshotProcs()
  const live = livePanePids(tmuxPath)
  // No live panes resolved (tmux query failed) -> refuse to reap: without the
  // live set we cannot tell orphans from the active session. Fail safe.
  if (live.size === 0) {
    logger.warn('channel-poller-reap: no live panes resolved, skipping detached-claude reap (fail-safe)')
    return []
  }
  const orphans = findOrphanChannelClaudes(procs, live, opts.channelNeedle)
  for (const pid of orphans) {
    killBunChildren(pid)
    try { process.kill(pid, 'SIGTERM') } catch { /* gone */ }
  }
  if (orphans.length > 0) {
    try { execFileSync('/bin/sleep', ['0.3'], { timeout: 2000 }) } catch { /* ignore */ }
    for (const pid of orphans) {
      try { process.kill(pid, 0); process.kill(pid, 'SIGKILL') } catch { /* gone */ }
    }
    logger.info({ reaped: orphans, channelNeedle: opts.channelNeedle ?? '(all)' }, 'channel-poller-reap: detached channel claudes killed')
  }
  return orphans
}
