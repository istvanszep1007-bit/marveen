import { describe, expect, it } from 'vitest'
import { advanceFailureState, failureBackoffMs, type RestartFailureState } from '../web/auto-restart-runner.js'

// WHY THIS EXISTS (2026-09-21, card ee485f5e).
//
// auto-restart-runner's own header already records this failure once: a throw
// inside performRestart left lastRestart unset, so the runner retried on every
// 60s tick, forever. That was fixed by removing ONE exception (launchctl ENOENT
// on Linux), not by bounding the retry -- so when the Linux leg started throwing
// "can't find pane" on 2026-09-21 it came straight back, and this time each
// retry ran a destructive pre-respawn reap first: ~40 restarts of the Telegram
// bridge between 03:00 and 06:31, and two of Istvan's messages unanswered.
//
// The property under test is the one that failed: consecutive failures must
// SPREAD OUT and then STOP, without ever silently marking the slot as done on
// the first failure.

function replay(ticks: number, tickMs = 60_000): { attempts: number[]; gaveUpAt: number | null } {
  // Simulate the runner: a tick every 60s, the restart throwing every time.
  let state: RestartFailureState | null = null
  const attempts: number[] = []
  let gaveUpAt: number | null = null
  for (let i = 0; i < ticks; i++) {
    const now = i * tickMs
    if (state && now < state.nextAttemptMs) continue // backoff window
    attempts.push(now)
    const verdict = advanceFailureState(state, now)
    if (verdict.giveUp) { gaveUpAt = now; break }
    state = verdict.next
  }
  return { attempts, gaveUpAt }
}

describe('advanceFailureState -- a failing restart cannot re-fire every tick', () => {
  it('does NOT attempt on every 60s tick', () => {
    const { attempts } = replay(60) // one hour of ticks
    expect(attempts.length).toBeLessThan(10)
  })

  it('gives up after the attempt cap instead of retrying forever', () => {
    const { attempts, gaveUpAt } = replay(600) // ten hours of ticks
    expect(gaveUpAt).not.toBeNull()
    expect(attempts).toHaveLength(5)
  })

  it('spreads the attempts out: 0s, 1m, 3m, 7m, 15m', () => {
    const { attempts } = replay(600)
    expect(attempts).toEqual([0, 60_000, 180_000, 420_000, 900_000])
  })

  it('the FIRST failure retries soon -- a transient error must not skip the slot', () => {
    const v = advanceFailureState(null, 1_000)
    expect(v.giveUp).toBe(false)
    if (!v.giveUp) expect(v.next.nextAttemptMs - 1_000).toBe(60_000)
  })

  it('keeps firstMs across attempts so the give-up line can report the span', () => {
    let state: RestartFailureState | null = null
    for (const now of [0, 60_000, 180_000]) {
      const v = advanceFailureState(state, now)
      if (v.giveUp) throw new Error('gave up too early')
      state = v.next
    }
    expect(state!.firstMs).toBe(0)
  })

  it('caps the backoff at 15 minutes rather than growing without bound', () => {
    expect(failureBackoffMs(1)).toBe(60_000)
    expect(failureBackoffMs(4)).toBe(480_000)
    expect(failureBackoffMs(9)).toBe(900_000)
    expect(failureBackoffMs(99)).toBe(900_000)
  })

  it('treats a nonsense failure count as the first attempt, not as zero wait', () => {
    expect(failureBackoffMs(0)).toBe(60_000)
    expect(failureBackoffMs(-3)).toBe(60_000)
  })

  it('honours a lower cap when the caller passes one', () => {
    expect(advanceFailureState(null, 0, 1).giveUp).toBe(true)
  })
})
