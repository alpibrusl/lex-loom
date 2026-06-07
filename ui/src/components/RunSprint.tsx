import { useState, useEffect, useRef } from 'react'
import { runSprint, getSprintStatus } from '../api'
import type { PhaseTransition } from '../types'

const PRESETS = [
  {
    label: 'Event System',
    emoji: '⚡',
    description: '3-module library · parallel build+QA',
    complex: true,
    request: 'Build a Python event processing library with three independent modules that must each be separately testable: (1) PriorityEventQueue class using heapq for priority-ordered delivery, supporting push(event, priority) and pop() -> event; (2) EventRouter that maps event types to handler functions via register(event_type, handler) and dispatch(event) -> any; (3) EventLog that records all dispatched events with timestamps, supports replay() -> list and clear(). Each module has its own test suite.',
  },
  {
    label: 'Order Validator',
    emoji: '📦',
    description: 'Single function with edge cases',
    complex: false,
    request: 'Write a Python function validate_order(order: dict) -> tuple[bool, str] that checks: items key exists and is a non-empty list, each item has price > 0 and qty > 0 as numbers, customer_id is a non-empty string. Returns (True, "ok") on success, (False, reason) on first failure.',
  },
  {
    label: 'Token Bucket',
    emoji: '🪣',
    description: 'Thread-safe rate limiter class',
    complex: false,
    request: 'Write a Python class TokenBucket(rate: float, capacity: float) implementing a token bucket rate limiter. Method consume(tokens: float = 1) -> bool returns True if tokens were consumed, False if insufficient. Thread-safe with threading.Lock. Tokens refill at rate/second up to capacity.',
  },
]

const PHASES = ['Intake', 'Design', 'Implementation', 'QA', 'Demo', 'Digest', 'Improve']

function randomHex(n: number) {
  return Array.from(crypto.getRandomValues(new Uint8Array(n)))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

interface Props {
  onComplete: (sprintId: string) => void
  onClose: () => void
}

export default function RunSprint({ onComplete, onClose }: Props) {
  const [step, setStep] = useState<'pick' | 'running' | 'done'>('pick')
  const [selected, setSelected] = useState(0)
  const [custom, setCustom] = useState('')
  const [sprintId, setSprintId] = useState('')
  const [transitions, setTransitions] = useState<PhaseTransition[]>([])
  const [result, setResult] = useState<{ success: boolean; summary: string } | null>(null)
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)

  function stopPoll() {
    if (pollRef.current) clearInterval(pollRef.current)
  }

  useEffect(() => () => stopPoll(), [])

  const currentRequest = selected < PRESETS.length ? PRESETS[selected].request : custom

  const currentPhase = (() => {
    if (transitions.length === 0) return 'Intake'
    return transitions[transitions.length - 1].to
  })()

  const donePhases = transitions.map(t => t.from)

  async function handleRun() {
    if (!currentRequest.trim()) return
    const sid = 'sprint-' + randomHex(8)
    setSprintId(sid)
    setStep('running')
    setTransitions([])

    pollRef.current = setInterval(async () => {
      try {
        const status = await getSprintStatus(sid)
        if (status.transitions?.length) setTransitions(status.transitions)
      } catch {}
    }, 2000)

    try {
      const res = await runSprint({ sprint_id: sid, request: currentRequest, model: 'gemini-3.5-flash' })
      stopPoll()
      setResult(res)
      setStep('done')
    } catch {
      stopPoll()
      setResult({ success: false, summary: 'Network error — is the Loom server running?' })
      setStep('done')
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4" onClick={e => { if (e.target === e.currentTarget) onClose() }}>
      <div className="absolute inset-0 bg-black/70 backdrop-blur-sm" />
      <div className="relative bg-surface border border-border rounded-2xl w-full max-w-2xl shadow-2xl fade-in">

        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-border">
          <div>
            <h2 className="text-slate-100 font-semibold">
              {step === 'pick' && 'New Sprint'}
              {step === 'running' && <span className="flex items-center gap-2">Running Sprint <span className="font-mono text-sm text-muted">{sprintId.slice(0, 20)}</span></span>}
              {step === 'done' && (result?.success ? '✓ Sprint Complete' : '✗ Sprint Failed')}
            </h2>
            {step === 'pick' && <p className="text-muted text-sm mt-0.5">Pick a scenario or write your own</p>}
          </div>
          <button onClick={onClose} className="text-muted hover:text-slate-200 text-xl leading-none">×</button>
        </div>

        {/* Pick step */}
        {step === 'pick' && (
          <div className="p-6 space-y-4">
            <div className="grid grid-cols-3 gap-3">
              {PRESETS.map((p, i) => (
                <button
                  key={i}
                  onClick={() => setSelected(i)}
                  className={`text-left p-3 rounded-lg border transition-all ${
                    selected === i
                      ? 'border-emerald-500 bg-emerald-950/40'
                      : 'border-border bg-bg hover:border-slate-500'
                  }`}
                >
                  <div className="text-xl mb-1">{p.emoji}</div>
                  <div className="flex items-center gap-1.5">
                    <span className="text-slate-200 text-sm font-medium">{p.label}</span>
                    {p.complex && <span className="text-[9px] px-1 py-0.5 rounded bg-indigo-900/60 text-indigo-300 font-semibold">MULTI-NODE</span>}
                  </div>
                  <div className="text-muted text-xs mt-0.5">{p.description}</div>
                </button>
              ))}
            </div>

            {selected < PRESETS.length ? (
              <div className="bg-bg rounded-lg p-3 border border-border">
                <p className="text-muted text-xs mb-1">Sprint goal</p>
                <p className="text-slate-300 text-sm leading-relaxed">{PRESETS[selected].request}</p>
              </div>
            ) : (
              <textarea
                className="w-full bg-bg border border-border rounded-lg p-3 text-slate-300 text-sm resize-none h-28 focus:outline-none focus:border-emerald-500 placeholder-muted"
                placeholder="Describe what you want built..."
                value={custom}
                onChange={e => setCustom(e.target.value)}
              />
            )}

            <div className="flex justify-between items-center pt-1">
              <button
                onClick={() => setSelected(PRESETS.length)}
                className={`text-sm ${selected === PRESETS.length ? 'text-emerald-400' : 'text-muted hover:text-slate-300'}`}
              >
                + Custom goal
              </button>
              <button
                onClick={handleRun}
                disabled={!currentRequest.trim()}
                className="px-5 py-2 bg-emerald-600 hover:bg-emerald-500 disabled:bg-slate-700 disabled:text-muted rounded-lg text-sm font-semibold text-white transition-colors"
              >
                Run Sprint →
              </button>
            </div>
          </div>
        )}

        {/* Running step */}
        {step === 'running' && (
          <div className="p-6 space-y-6">
            <div className="space-y-2">
              {PHASES.map((phase, i) => {
                const done = donePhases.includes(phase)
                const active = currentPhase === phase
                return (
                  <div key={phase} className={`flex items-center gap-3 py-2 px-3 rounded-lg transition-all ${active ? 'bg-emerald-950/30 border border-emerald-800/50' : ''}`}>
                    <div className={`w-5 h-5 rounded-full flex items-center justify-center flex-shrink-0 text-xs ${
                      done ? 'bg-emerald-600 text-white' :
                      active ? 'bg-emerald-900 border border-emerald-500 pulse-soft' :
                      'bg-slate-800 border border-border'
                    }`}>
                      {done ? '✓' : active ? '·' : <span className="text-muted">{i + 1}</span>}
                    </div>
                    <span className={`text-sm font-medium ${
                      done ? 'text-emerald-400' :
                      active ? 'text-slate-100' :
                      'text-muted'
                    }`}>{phase}</span>
                    {active && <span className="text-muted text-xs ml-auto pulse-soft">running…</span>}
                    {done && transitions.find(t => t.from === phase) && (
                      <span className="text-muted text-xs ml-auto font-mono">
                        {new Date(transitions.find(t => t.from === phase)!.ts).toLocaleTimeString()}
                      </span>
                    )}
                  </div>
                )
              })}
            </div>
            <p className="text-center text-muted text-sm">Agents are working… this takes ~90 seconds</p>
          </div>
        )}

        {/* Done step */}
        {step === 'done' && result && (
          <div className="p-6 space-y-4 fade-in">
            <div className={`rounded-xl p-5 border ${
              result.success
                ? 'bg-emerald-950/40 border-emerald-700'
                : 'bg-rose-950/40 border-rose-700'
            }`}>
              <div className={`text-3xl font-bold mb-2 ${result.success ? 'text-emerald-400' : 'text-rose-400'}`}>
                {result.success ? '✓ PASS' : '✗ FAIL'}
              </div>
              <p className="text-slate-300 text-sm leading-relaxed">{result.summary}</p>
            </div>

            <div className="flex gap-3">
              <button
                onClick={() => onComplete(sprintId)}
                className="flex-1 px-4 py-2 bg-slate-700 hover:bg-slate-600 rounded-lg text-sm font-medium text-slate-200 transition-colors"
              >
                View sprint trail →
              </button>
              <button
                onClick={onClose}
                className="px-4 py-2 text-muted hover:text-slate-200 text-sm transition-colors"
              >
                Close
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
