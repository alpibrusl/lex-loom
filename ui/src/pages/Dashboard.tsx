import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { getSeries } from '../api'
import type { SprintStat } from '../types'
import SeriesChart from '../components/SeriesChart'
import RunSprint from '../components/RunSprint'

function SprintRow({ s }: { s: SprintStat }) {
  const navigate = useNavigate()
  return (
    <tr
      onClick={() => navigate(`/sprint/${s.sprint_id}`)}
      className="border-b border-border hover:bg-slate-800/30 cursor-pointer transition-colors"
    >
      <td className="py-3 px-4">
        <span className="font-mono text-sm text-slate-300">{s.sprint_id.replace('sprint-', '').slice(0, 16)}</span>
      </td>
      <td className="py-3 px-4 text-muted text-sm">{new Date(s.ts).toLocaleString()}</td>
      <td className="py-3 px-4">
        <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold ${
          s.success ? 'bg-emerald-900/50 text-emerald-400' : 'bg-rose-900/50 text-rose-400'
        }`}>
          {s.success ? '✓ pass' : '✗ fail'}
        </span>
      </td>
      <td className="py-3 px-4">
        {s.qa_verdict ? (
          <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold ${
            s.qa_verdict === 'PASS' ? 'bg-emerald-900/50 text-emerald-400' : 'bg-rose-900/50 text-rose-400'
          }`}>
            QA {s.qa_verdict}
          </span>
        ) : (
          <span className="text-muted text-xs">—</span>
        )}
      </td>
      <td className="py-3 px-4 text-right">
        <span className="text-muted text-xs">→</span>
      </td>
    </tr>
  )
}

export default function Dashboard() {
  const [series, setSeries] = useState<SprintStat[]>([])
  const [loading, setLoading] = useState(true)
  const [showRunner, setShowRunner] = useState(false)
  const navigate = useNavigate()

  async function load() {
    try {
      const d = await getSeries()
      setSeries(d.series.slice().reverse())
    } catch {}
    setLoading(false)
  }

  useEffect(() => { load() }, [])

  function handleComplete(sprintId: string) {
    setShowRunner(false)
    navigate(`/sprint/${sprintId}`)
  }

  const passing = series.filter(s => s.success).length
  const qaPass = series.filter(s => s.qa_verdict === 'PASS').length

  return (
    <div className="max-w-7xl mx-auto px-6 py-8 space-y-6">

      {/* Hero */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-100">Sprint Dashboard</h1>
          <p className="text-muted mt-1 text-sm">
            Each sprint runs a multi-agent pipeline. Agents improve themselves after every cycle.
          </p>
        </div>
        <button
          onClick={() => setShowRunner(true)}
          className="flex items-center gap-2 px-5 py-2.5 bg-emerald-600 hover:bg-emerald-500 rounded-lg text-sm font-semibold text-white transition-colors shadow-lg shadow-emerald-900/30"
        >
          <span>▶</span> Run Sprint
        </button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-4 gap-4">
        {[
          { label: 'Total sprints', value: series.length, color: 'text-slate-100' },
          { label: 'Succeeded', value: passing, color: 'text-emerald-400' },
          { label: 'QA passed', value: qaPass, color: 'text-emerald-400' },
          { label: 'Pass rate', value: series.length ? `${Math.round(qaPass / series.length * 100)}%` : '—', color: qaPass > passing / 2 ? 'text-emerald-400' : 'text-amber-400' },
        ].map(stat => (
          <div key={stat.label} className="bg-surface border border-border rounded-xl p-4">
            <p className="text-muted text-xs mb-1">{stat.label}</p>
            <p className={`text-2xl font-bold ${stat.color}`}>{stat.value}</p>
          </div>
        ))}
      </div>

      {/* Chart */}
      {loading ? (
        <div className="bg-surface border border-border rounded-xl p-8 flex items-center justify-center">
          <span className="text-muted text-sm pulse-soft">Loading series…</span>
        </div>
      ) : (
        <SeriesChart series={series.slice().reverse()} />
      )}

      {/* Sprint list */}
      <div className="bg-surface border border-border rounded-xl overflow-hidden">
        <div className="px-6 py-4 border-b border-border flex items-center justify-between">
          <h2 className="text-slate-100 font-semibold">Recent Sprints</h2>
          <button onClick={load} className="text-muted text-xs hover:text-slate-300 transition-colors">↺ Refresh</button>
        </div>
        {loading ? (
          <div className="py-12 text-center text-muted text-sm pulse-soft">Loading…</div>
        ) : series.length === 0 ? (
          <div className="py-12 text-center">
            <p className="text-muted text-sm mb-3">No sprints yet</p>
            <button onClick={() => setShowRunner(true)} className="text-emerald-400 text-sm hover:text-emerald-300 transition-colors">
              Run your first sprint →
            </button>
          </div>
        ) : (
          <table className="w-full">
            <thead>
              <tr className="border-b border-border text-left">
                <th className="py-2 px-4 text-muted text-xs font-medium">Sprint ID</th>
                <th className="py-2 px-4 text-muted text-xs font-medium">Started</th>
                <th className="py-2 px-4 text-muted text-xs font-medium">Result</th>
                <th className="py-2 px-4 text-muted text-xs font-medium">QA</th>
                <th className="py-2 px-4" />
              </tr>
            </thead>
            <tbody>
              {series.map(s => <SprintRow key={s.sprint_id} s={s} />)}
            </tbody>
          </table>
        )}
      </div>

      {showRunner && <RunSprint onComplete={handleComplete} onClose={() => setShowRunner(false)} />}
    </div>
  )
}
