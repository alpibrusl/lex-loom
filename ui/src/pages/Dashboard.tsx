import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { getSeries, getSprintTrail } from '../api'
import type { SprintStat } from '../types'
import SeriesChart from '../components/SeriesChart'
import RunSprint from '../components/RunSprint'

function safeJson(s: string): Record<string, unknown> {
  try { return JSON.parse(s) || {} } catch { return {} }
}

function SprintCard({ s, request }: { s: SprintStat; request?: string }) {
  const navigate = useNavigate()
  const short = s.sprint_id.replace('sprint-', '').slice(0, 12)
  const date = new Date(s.ts)

  return (
    <div
      onClick={() => navigate(`/sprint/${s.sprint_id}`)}
      className="bg-surface border border-border rounded-xl p-5 cursor-pointer hover:border-slate-500 transition-all group"
    >
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <span className={`px-2.5 py-1 rounded-lg text-xs font-bold ${
            s.success ? 'bg-emerald-900/50 text-emerald-400' : 'bg-rose-900/50 text-rose-400'
          }`}>
            {s.success ? '✓ PASS' : '✗ FAIL'}
          </span>
          {s.qa_verdict && (
            <span className={`px-2 py-0.5 rounded text-xs font-semibold ${
              s.qa_verdict === 'PASS' ? 'bg-emerald-900/40 text-emerald-500' : 'bg-rose-900/40 text-rose-500'
            }`}>
              QA {s.qa_verdict}
            </span>
          )}
        </div>
        <span className="text-muted text-xs">
          {date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })} {date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}
        </span>
      </div>

      {/* Goal */}
      <p className="text-slate-300 text-sm leading-relaxed line-clamp-2 mb-3">
        {request || <span className="text-muted italic">Goal not recorded — run a new sprint to see it here</span>}
      </p>

      <div className="flex items-center justify-between">
        <span className="font-mono text-xs text-muted">{short}</span>
        <span className="text-muted text-xs group-hover:text-slate-300 transition-colors">View sprint →</span>
      </div>
    </div>
  )
}

export default function Dashboard() {
  const [series, setSeries] = useState<SprintStat[]>([])
  const [requests, setRequests] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [showRunner, setShowRunner] = useState(false)
  const navigate = useNavigate()

  async function load() {
    try {
      const d = await getSeries()
      const sorted = d.series.slice().reverse()
      setSeries(sorted)
      setLoading(false)

      // Load request text for each sprint (from sprint_started event)
      for (const s of sorted.slice(0, 10)) {
        getSprintTrail(s.sprint_id).then(trail => {
          const startEv = trail.events.find(e => e.event_kind === 'sprint_started')
          if (startEv) {
            const data = safeJson(startEv.data_json)
            if (typeof data.request === 'string') {
              setRequests(prev => ({ ...prev, [s.sprint_id]: data.request as string }))
            }
          }
        }).catch(() => {})
      }
    } catch {
      setLoading(false)
    }
  }

  useEffect(() => { load() }, [])

  function handleComplete(sprintId: string) {
    setShowRunner(false)
    navigate(`/sprint/${sprintId}`)
  }

  const passing = series.filter(s => s.success).length
  const qaPass = series.filter(s => s.qa_verdict === 'PASS').length
  const total = series.length

  return (
    <div className="max-w-7xl mx-auto px-6 py-8 space-y-6">

      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-100">Sprint Dashboard</h1>
          <p className="text-muted mt-1 text-sm max-w-xl">
            Each sprint is a multi-agent problem-solving cycle. Agents earn trust, get improved by AI, and selected automatically next time.
          </p>
        </div>
        <button
          onClick={() => setShowRunner(true)}
          className="flex items-center gap-2 px-5 py-2.5 bg-emerald-600 hover:bg-emerald-500 rounded-lg text-sm font-semibold text-white transition-colors shadow-lg shadow-emerald-900/30 flex-shrink-0"
        >
          ▶ Run Sprint
        </button>
      </div>

      {/* Stats row */}
      <div className="grid grid-cols-4 gap-4">
        {[
          { label: 'Sprints run', value: total, sub: 'total', color: 'text-slate-100' },
          { label: 'Succeeded', value: passing, sub: `${total ? Math.round(passing/total*100) : 0}%`, color: 'text-emerald-400' },
          { label: 'QA verified', value: qaPass, sub: 'code-executed', color: 'text-emerald-400' },
          { label: 'QA pass rate', value: total ? `${Math.round(qaPass/total*100)}%` : '—', sub: 'improving over time', color: qaPass >= passing*0.7 ? 'text-emerald-400' : 'text-amber-400' },
        ].map(stat => (
          <div key={stat.label} className="bg-surface border border-border rounded-xl p-4">
            <p className="text-muted text-xs mb-1">{stat.label}</p>
            <p className={`text-3xl font-bold ${stat.color}`}>{stat.value}</p>
            <p className="text-muted text-xs mt-1">{stat.sub}</p>
          </div>
        ))}
      </div>

      {/* Chart */}
      {!loading && <SeriesChart series={series.slice().reverse()} />}

      {/* Sprint cards */}
      <div>
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-slate-100 font-semibold">Sprint History</h2>
          <button onClick={load} className="text-muted text-xs hover:text-slate-300 transition-colors">↺ Refresh</button>
        </div>

        {loading ? (
          <div className="py-12 text-center text-muted text-sm pulse-soft">Loading…</div>
        ) : series.length === 0 ? (
          <div className="bg-surface border border-border rounded-xl py-16 text-center">
            <p className="text-slate-300 font-medium mb-2">No sprints yet</p>
            <p className="text-muted text-sm mb-4">Click "Run Sprint" to see agents work</p>
            <button onClick={() => setShowRunner(true)} className="text-emerald-400 hover:text-emerald-300 text-sm transition-colors">
              Start your first sprint →
            </button>
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-4">
            {series.map(s => (
              <SprintCard key={s.sprint_id} s={s} request={requests[s.sprint_id]} />
            ))}
          </div>
        )}
      </div>

      {showRunner && <RunSprint onComplete={handleComplete} onClose={() => setShowRunner(false)} />}
    </div>
  )
}
