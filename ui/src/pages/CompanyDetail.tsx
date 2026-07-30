import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { getCompanyDetail, getSprintGraph, getSprintTrail } from '../api'
import type { CompanyDetail as CompanyDetailData, TrailEvent, CompanyContact } from '../types'
import PhaseGraph, { type GraphData, graphStatusFromTrail } from '../components/PhaseGraph'

const STAGE_STYLE: Record<string, string> = {
  ideation: 'bg-slate-800 text-slate-300',
  growth: 'bg-emerald-900/50 text-emerald-400',
  maintenance: 'bg-sky-900/50 text-sky-400',
  sunset: 'bg-amber-900/50 text-amber-400',
}

function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

function StatTile({ label, value, sub, color }: { label: string; value: string | number; sub: string; color: string }) {
  return (
    <div className="bg-surface border border-border rounded-xl p-4">
      <p className="text-muted text-xs mb-1">{label}</p>
      <p className={`text-3xl font-bold ${color}`}>{value}</p>
      <p className="text-muted text-xs mt-1">{sub}</p>
    </div>
  )
}

function ProseSection({ title, body }: { title: string; body: string }) {
  if (!body) return null
  return (
    <div className="bg-surface border border-border rounded-xl p-5">
      <h2 className="text-slate-100 font-semibold mb-2">{title}</h2>
      <pre className="text-slate-300 text-sm whitespace-pre-wrap font-sans leading-relaxed">{body}</pre>
    </div>
  )
}

function ListSection({ title, items, emptyLabel, cardCls }: { title: string; items: string[]; emptyLabel: string; cardCls?: string }) {
  return (
    <div className="bg-surface border border-border rounded-xl p-5">
      <h2 className="text-slate-100 font-semibold mb-3">{title}</h2>
      {items.length === 0 ? (
        <p className="text-muted text-sm">{emptyLabel}</p>
      ) : (
        <div className="space-y-2">
          {items.map((item, i) => (
            <pre key={i} className={`text-sm whitespace-pre-wrap font-sans leading-relaxed rounded-lg p-3 ${cardCls || 'text-slate-300 bg-bg/40'}`}>{item}</pre>
          ))}
        </div>
      )}
    </div>
  )
}

// "Who do I ask about X" -- relationships.lex wired into a company
// accountability graph (#151). A human contact gets a real mailto/slack
// link; a pool-agent contact has no such thing (Cast selects it
// dynamically per task), so its measured record is shown instead.
function ContactRow({ ct }: { ct: CompanyContact }) {
  return (
    <div className="flex items-center gap-3 px-3 py-2 rounded-lg bg-bg/40 text-sm">
      <span className="px-2 py-0.5 rounded text-xs font-semibold bg-slate-800 text-slate-300 flex-shrink-0">{ct.oracle}</span>
      <span className="text-slate-300 truncate">{ct.name}</span>
      {ct.contact ? (
        <a href={ct.contact} className="text-emerald-400 hover:text-emerald-300 text-xs font-mono ml-auto transition-colors">{ct.contact}</a>
      ) : (
        <span className="text-muted text-xs ml-auto">{ct.kind}{ct.note ? ` · ${ct.note}` : ''}</span>
      )}
    </div>
  )
}

function ContactsSection({ contacts }: { contacts: CompanyContact[] }) {
  return (
    <div className="bg-surface border border-border rounded-xl p-5">
      <h2 className="text-slate-100 font-semibold mb-3">Contacts — who to ask</h2>
      {contacts.length === 0 ? (
        <p className="text-muted text-sm">No contacts configured yet.</p>
      ) : (
        <div className="space-y-1.5">
          {contacts.map((ct, i) => <ContactRow key={i} ct={ct} />)}
        </div>
      )}
    </div>
  )
}

// Latest iteration's agent pipeline, embedded inline — reuses PhaseGraph,
// the same component SprintDetail uses, fed by the same /api/sprint-graph/*id
// endpoint (no new backend route for this).
function LatestIterationGraph({ sprintId }: { sprintId: string }) {
  const [graph, setGraph] = useState<GraphData | null>(null)
  const [events, setEvents] = useState<TrailEvent[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!sprintId) { setLoading(false); return }
    let alive = true
    async function load() {
      try {
        const [gr, tr] = await Promise.all([
          getSprintGraph(sprintId),
          getSprintTrail(sprintId),
        ])
        if (!alive) return
        if (gr.graph) setGraph(gr.graph)
        setEvents(tr.events || [])
      } finally {
        if (alive) setLoading(false)
      }
    }
    load()
    return () => { alive = false }
  }, [sprintId])

  if (loading || !graph) return null
  const { accepted, active } = graphStatusFromTrail(events)

  return (
    <div className="bg-surface border border-border rounded-xl p-5">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-slate-100 font-semibold">Latest iteration</h2>
        <Link to={`/sprint/${encodeURIComponent(sprintId)}`} className="text-muted text-xs hover:text-slate-300 transition-colors">
          {sprintId} →
        </Link>
      </div>
      <PhaseGraph graph={graph} acceptedNodes={accepted} activeNode={active} />
    </div>
  )
}

export default function CompanyDetail() {
  const { id } = useParams<{ id: string }>()
  const [c, setC] = useState<CompanyDetailData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  async function load() {
    if (!id) return
    setLoading(true)
    setError(null)
    try {
      setC(await getCompanyDetail(id))
    } catch (e) {
      setError(e instanceof Error ? e.message : 'failed to load company')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { load() }, [id])

  if (loading) return <div className="max-w-5xl mx-auto px-6 py-12 text-center text-muted text-sm pulse-soft">Loading…</div>
  if (error || !c) return <div className="max-w-5xl mx-auto px-6 py-12 text-center text-rose-400 text-sm">{error || 'not found'}</div>

  const stageCls = STAGE_STYLE[c.stage] || 'bg-slate-800 text-slate-300'
  const liveCls = c.live_status === 'up' ? 'bg-emerald-900/50 text-emerald-400'
    : c.live_status === 'down' ? 'bg-rose-900/50 text-rose-400'
    : 'bg-slate-800 text-slate-400'

  return (
    <div className="max-w-5xl mx-auto px-6 py-8 space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-2 mb-2">
            <span className={`px-2.5 py-1 rounded-lg text-xs font-bold uppercase tracking-wide ${stageCls}`}>{c.stage}</span>
            <span className="font-mono text-muted text-xs">{c.id}</span>
          </div>
          <h1 className="text-xl font-bold text-slate-100 max-w-2xl">{c.goal}</h1>
        </div>
        <button onClick={load} className="text-muted text-xs hover:text-slate-300 transition-colors flex-shrink-0">↺ Refresh</button>
      </div>

      {/* Product status */}
      <div className="bg-surface border border-border rounded-xl p-5 flex items-center gap-4">
        <span className={`px-3 py-1.5 rounded-lg text-sm font-bold ${liveCls}`}>
          {c.live_status === 'up' ? '● LIVE' : c.live_status === 'down' ? '● DOWN' : '○ UNKNOWN'}
        </span>
        {c.live_url ? (
          <a href={c.live_url} target="_blank" rel="noreferrer" className="text-emerald-400 hover:text-emerald-300 text-sm font-mono transition-colors">
            {c.live_url} ↗
          </a>
        ) : (
          <span className="text-muted text-sm">No product launched yet</span>
        )}
        <span className="ml-auto text-muted text-sm">{formatCents(c.spend_cents)} spent</span>
      </div>

      {/* Latest iteration DAG */}
      <LatestIterationGraph sprintId={c.latest_sprint_id} />

      {/* Operate stat row */}
      <div className="grid grid-cols-4 gap-4">
        <StatTile label="Open incidents" value={c.operate_metrics.open_incidents} sub={`${c.operate_metrics.resolved_count} resolved`} color={c.operate_metrics.open_incidents > 0 ? 'text-rose-400' : 'text-emerald-400'} />
        <StatTile label="Escalated" value={c.operate_metrics.escalated_count} sub="need review" color={c.operate_metrics.escalated_count > 0 ? 'text-amber-400' : 'text-slate-100'} />
        <StatTile label="Hit rate" value={`${c.operate_metrics.hit_rate_pct}%`} sub={c.operate_metrics.hit_rate_trend} color="text-slate-100" />
        <StatTile label="Verified actions" value={c.operate_metrics.verified_effects} sub={`${c.operate_metrics.avg_evidence_cost_milli}m avg evidence`} color="text-slate-100" />
      </div>

      {/* Escalations — need human eyes */}
      <ListSection title="Escalations needing review" items={c.escalations} emptyLabel="(none)" cardCls="text-amber-200 bg-amber-950/40 border border-amber-800/50" />

      <ContactsSection contacts={c.contacts} />

      {/* Iterations */}
      <div className="bg-surface border border-border rounded-xl p-5">
        <h2 className="text-slate-100 font-semibold mb-3">Iterations</h2>
        <div className="space-y-1.5">
          {c.iterations.map(it => (
            <Link
              key={it.idx}
              to={`/sprint/${encodeURIComponent(it.sprint_id)}`}
              className="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-bg/40 transition-colors text-sm"
            >
              <span className="font-mono text-muted w-10">#{it.idx}</span>
              <span className={`px-2 py-0.5 rounded text-xs font-semibold ${it.status === 'success' ? 'bg-emerald-900/40 text-emerald-500' : 'bg-slate-800 text-slate-400'}`}>
                {it.status}
              </span>
              <span className="text-slate-300 truncate flex-1">{it.goal}</span>
              <span className="text-muted text-xs">→</span>
            </Link>
          ))}
        </div>
      </div>

      <ProseSection title="Shipped so far" body={c.shipped_summary} />
      <ProseSection title="Backlog" body={c.backlog_summary} />
      <ProseSection title="Operate signals" body={c.operate_signals} />
      <ListSection title="Recent decisions" items={c.decisions} emptyLabel="(none yet)" />
      <ListSection title="Recent stage transitions" items={c.stage_transitions} emptyLabel="(none yet)" />
    </div>
  )
}
