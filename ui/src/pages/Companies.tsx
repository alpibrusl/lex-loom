import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { getCompanies } from '../api'
import type { CompanyStat } from '../types'

const STAGE_STYLE: Record<string, string> = {
  ideation: 'bg-slate-800 text-slate-300',
  growth: 'bg-emerald-900/50 text-emerald-400',
  maintenance: 'bg-sky-900/50 text-sky-400',
  sunset: 'bg-amber-900/50 text-amber-400',
}

function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

function CompanyCard({ c }: { c: CompanyStat }) {
  const navigate = useNavigate()
  const stageCls = STAGE_STYLE[c.stage] || 'bg-slate-800 text-slate-300'

  return (
    <div
      onClick={() => navigate(`/company/${c.id}`)}
      className="bg-surface border border-border rounded-xl p-5 cursor-pointer hover:border-slate-500 transition-all group"
    >
      <div className="flex items-start justify-between mb-3">
        <span className={`px-2.5 py-1 rounded-lg text-xs font-bold uppercase tracking-wide ${stageCls}`}>
          {c.stage}
        </span>
        {c.open_incidents > 0 && (
          <span className="px-2 py-0.5 rounded text-xs font-semibold bg-rose-900/50 text-rose-400">
            {c.open_incidents} open incident{c.open_incidents === 1 ? '' : 's'}
          </span>
        )}
      </div>

      <p className="text-slate-300 text-sm leading-relaxed line-clamp-2 mb-3">{c.goal}</p>

      <div className="flex items-center justify-between text-xs">
        <span className="font-mono text-muted">{c.id}</span>
        <div className="flex items-center gap-3 text-muted">
          <span>{c.iterations} iteration{c.iterations === 1 ? '' : 's'}</span>
          <span>{formatCents(c.spend_cents)}</span>
        </div>
      </div>
    </div>
  )
}

export default function Companies() {
  const [companies, setCompanies] = useState<CompanyStat[]>([])
  const [loading, setLoading] = useState(true)

  async function load() {
    setLoading(true)
    try {
      const d = await getCompanies()
      setCompanies(d.companies)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { load() }, [])

  return (
    <div className="max-w-7xl mx-auto px-6 py-8 space-y-6">
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-100">Companies</h1>
          <p className="text-muted mt-1 text-sm max-w-xl">
            A company is a persistent goal that produces a series of iterating sprints — build, launch, and watch over the result.
          </p>
        </div>
        <button onClick={load} className="text-muted text-xs hover:text-slate-300 transition-colors flex-shrink-0">↺ Refresh</button>
      </div>

      {loading ? (
        <div className="py-12 text-center text-muted text-sm pulse-soft">Loading…</div>
      ) : companies.length === 0 ? (
        <div className="bg-surface border border-border rounded-xl py-16 text-center">
          <p className="text-slate-300 font-medium mb-2">No companies yet</p>
          <p className="text-muted text-sm">Run <code className="text-slate-400">bin/run-company.sh</code> to see one here.</p>
        </div>
      ) : (
        <div className="grid grid-cols-2 gap-4">
          {companies.map(c => <CompanyCard key={c.id} c={c} />)}
        </div>
      )}
    </div>
  )
}
