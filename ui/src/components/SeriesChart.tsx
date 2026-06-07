import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import type { SprintStat } from '../types'

interface Props {
  series: SprintStat[]
}

function short(id: string) {
  return id.replace('sprint-', '').slice(0, 8)
}

function color(s: SprintStat) {
  if (!s.success) return '#f85149'
  if (s.qa_verdict === 'PASS') return '#3fb950'
  if (s.qa_verdict === 'FAIL') return '#f85149'
  return '#d29922'
}

function CustomTooltip({ active, payload }: any) {
  if (!active || !payload?.length) return null
  const s: SprintStat = payload[0].payload
  return (
    <div className="bg-surface border border-border rounded-lg p-3 text-sm shadow-xl">
      <p className="font-mono text-slate-300 mb-1">{short(s.sprint_id)}</p>
      <p className="text-muted text-xs mb-2">{new Date(s.ts).toLocaleString()}</p>
      <div className="flex items-center gap-2">
        <span className={`px-2 py-0.5 rounded text-xs font-semibold ${
          s.success ? 'bg-emerald-900/60 text-emerald-400' : 'bg-rose-900/60 text-rose-400'
        }`}>
          {s.success ? 'SUCCESS' : 'FAILED'}
        </span>
        {s.qa_verdict && (
          <span className={`px-2 py-0.5 rounded text-xs font-semibold ${
            s.qa_verdict === 'PASS' ? 'bg-emerald-900/60 text-emerald-400' : 'bg-rose-900/60 text-rose-400'
          }`}>
            QA {s.qa_verdict}
          </span>
        )}
      </div>
    </div>
  )
}

export default function SeriesChart({ series }: Props) {
  const data = series.map(s => ({ ...s, value: 1 }))
  const passing = series.filter(s => s.success).length
  const qaPass = series.filter(s => s.qa_verdict === 'PASS').length
  const total = series.length

  return (
    <div className="bg-surface border border-border rounded-xl p-6">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h2 className="text-slate-100 font-semibold text-base">Sprint Series</h2>
          <p className="text-muted text-sm mt-0.5">
            {total} sprints · {passing} succeeded · {qaPass} QA passed
            {total > 0 && <span className="ml-2 text-emerald-400 font-medium">{Math.round(qaPass / total * 100)}% pass rate</span>}
          </p>
        </div>
        <div className="flex items-center gap-3 text-xs text-muted">
          <span className="flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-sm bg-emerald-500 inline-block" />PASS</span>
          <span className="flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-sm bg-rose-500 inline-block" />FAIL</span>
          <span className="flex items-center gap-1.5"><span className="w-2.5 h-2.5 rounded-sm bg-amber-500 inline-block" />QA unknown</span>
        </div>
      </div>

      {data.length === 0 ? (
        <div className="h-32 flex items-center justify-center text-muted text-sm">No sprints yet</div>
      ) : (
        <ResponsiveContainer width="100%" height={120}>
          <BarChart data={data} barCategoryGap="30%" margin={{ top: 4, right: 4, bottom: 4, left: 4 }}>
            <XAxis
              dataKey="sprint_id"
              tickFormatter={short}
              tick={{ fill: '#7d8590', fontSize: 11, fontFamily: 'JetBrains Mono' }}
              axisLine={false}
              tickLine={false}
            />
            <YAxis hide />
            <Tooltip content={<CustomTooltip />} cursor={{ fill: 'rgba(255,255,255,0.04)' }} />
            <Bar dataKey="value" radius={[3, 3, 0, 0]}>
              {data.map((s, i) => (
                <Cell key={i} fill={color(s)} fillOpacity={0.85} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      )}
    </div>
  )
}
