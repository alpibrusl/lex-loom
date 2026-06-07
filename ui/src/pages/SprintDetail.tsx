import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { getSprintTrail, getSprintDigest, getArtifact } from '../api'
import type { TrailEvent, DigestData } from '../types'
import TrailTimeline from '../components/TrailTimeline'

function QAPanel({ sprintId, events }: { sprintId: string; events: TrailEvent[] }) {
  const [verdict, setVerdict] = useState<{ verdict: string; reason: string; test_output: string } | null>(null)

  useEffect(() => {
    const ev = events.find(e => e.event_kind === 'node_accepted' && e.data_json.includes('qa'))
    if (!ev) return
    try {
      const d = JSON.parse(ev.data_json)
      if (d.artifact) {
        getArtifact(sprintId, d.artifact).then(r => {
          try { setVerdict(JSON.parse(r.content)) } catch {}
        }).catch(() => {})
      }
    } catch {}
  }, [events, sprintId])

  if (!verdict) return null

  const pass = verdict.verdict === 'PASS'
  return (
    <div className={`rounded-xl p-5 border ${pass ? 'bg-emerald-950/30 border-emerald-700/50' : 'bg-rose-950/30 border-rose-700/50'}`}>
      <div className="flex items-center gap-3 mb-3">
        <span className={`text-2xl font-bold ${pass ? 'text-emerald-400' : 'text-rose-400'}`}>
          QA: {verdict.verdict}
        </span>
        <span className={`text-xs px-2 py-0.5 rounded font-semibold ${pass ? 'bg-emerald-900/60 text-emerald-300' : 'bg-rose-900/60 text-rose-300'}`}>
          Verified by code execution
        </span>
      </div>
      <p className="text-slate-300 text-sm mb-3">{verdict.reason}</p>
      {verdict.test_output && (
        <div className="bg-black/40 rounded-lg p-3">
          <p className="text-muted text-xs mb-1 font-mono">Test output</p>
          <pre className="text-slate-400 text-xs font-mono overflow-auto max-h-32">{verdict.test_output}</pre>
        </div>
      )}
    </div>
  )
}

function DigestPanel({ data }: { data: DigestData }) {
  return (
    <div className="bg-surface border border-border rounded-xl p-5 space-y-4">
      <h3 className="text-slate-100 font-semibold flex items-center gap-2">
        <span>📝</span> Sprint Digest
      </h3>
      {data.summary && (
        <p className="text-slate-300 text-sm leading-relaxed">{data.summary}</p>
      )}
      {data.specs.length > 0 && (
        <div>
          <p className="text-muted text-xs mb-2 font-medium uppercase tracking-wide">Tightened Specs ({data.specs.length})</p>
          <div className="space-y-2">
            {data.specs.map((spec, i) => (
              <div key={i} className="bg-bg rounded-lg p-3 border border-border">
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-xs text-emerald-400 font-mono bg-emerald-900/30 px-1.5 py-0.5 rounded">{spec.node_role}</span>
                </div>
                <p className="text-slate-300 text-sm">{spec.spec_src}</p>
                <p className="text-muted text-xs mt-1">↑ {spec.reason}</p>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

export default function SprintDetail() {
  const { id } = useParams<{ id: string }>()
  const [events, setEvents] = useState<TrailEvent[]>([])
  const [digest, setDigest] = useState<DigestData | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!id) return
    Promise.all([
      getSprintTrail(id).then(d => setEvents(d.events)),
      getSprintDigest(id).then(d => setDigest(d)).catch(() => {}),
    ]).finally(() => setLoading(false))
  }, [id])

  const success = events.some(e => e.event_kind === 'sprint_complete' && e.data_json.includes('"success":true'))
  const failed = events.some(e => e.event_kind === 'sprint_failed')
  const startedAt = events.find(e => e.event_kind === 'sprint_started')?.ts

  return (
    <div className="max-w-7xl mx-auto px-6 py-8">
      <div className="mb-6">
        <Link to="/" className="text-muted text-sm hover:text-slate-300 transition-colors">← Dashboard</Link>
        <div className="flex items-center gap-3 mt-3">
          <h1 className="text-xl font-bold text-slate-100 font-mono">{id}</h1>
          {!loading && (
            <span className={`px-3 py-1 rounded-full text-sm font-semibold ${
              success ? 'bg-emerald-900/50 text-emerald-400' :
              failed ? 'bg-rose-900/50 text-rose-400' :
              'bg-amber-900/50 text-amber-400'
            }`}>
              {success ? '✓ Success' : failed ? '✗ Failed' : 'Running…'}
            </span>
          )}
          {startedAt && <span className="text-muted text-sm">{new Date(startedAt).toLocaleString()}</span>}
        </div>
      </div>

      {loading ? (
        <div className="text-muted text-sm pulse-soft py-12 text-center">Loading trail…</div>
      ) : (
        <div className="grid grid-cols-3 gap-6">
          {/* Timeline — 2/3 width */}
          <div className="col-span-2 space-y-4">
            <div className="bg-surface border border-border rounded-xl p-5">
              <h2 className="text-slate-100 font-semibold mb-4 flex items-center gap-2">
                <span>⟳</span> Agent Trail
                <span className="text-muted text-xs ml-auto font-normal">{events.length} events</span>
              </h2>
              <TrailTimeline events={events} />
            </div>
          </div>

          {/* Sidebar — 1/3 width */}
          <div className="space-y-4">
            <QAPanel sprintId={id!} events={events} />
            {digest && digest.specs.length > 0 && <DigestPanel data={digest} />}

            {/* Agent links */}
            <div className="bg-surface border border-border rounded-xl p-4">
              <h3 className="text-slate-100 font-semibold mb-3 text-sm">What happens next?</h3>
              <p className="text-muted text-xs leading-relaxed mb-3">
                The Scribe produced a Digest. The Improver rewrote agent prompts based on what failed.
                New agents start at higher attestation so Cast picks them next sprint.
              </p>
              <Link to="/agents" className="text-emerald-400 text-sm hover:text-emerald-300 transition-colors">
                View Agent Pool →
              </Link>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
