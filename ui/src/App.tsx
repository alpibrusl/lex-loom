import { BrowserRouter, Routes, Route, NavLink } from 'react-router-dom'
import Dashboard from './pages/Dashboard'
import SprintDetail from './pages/SprintDetail'
import Agents from './pages/Agents'

function Nav() {
  const cls = ({ isActive }: { isActive: boolean }) =>
    `px-3 py-1.5 rounded text-sm font-medium transition-colors ${
      isActive
        ? 'bg-slate-700 text-slate-100'
        : 'text-slate-400 hover:text-slate-200 hover:bg-slate-800'
    }`

  return (
    <nav className="fixed top-0 inset-x-0 z-40 border-b border-border bg-bg/95 backdrop-blur">
      <div className="max-w-7xl mx-auto px-6 h-14 flex items-center gap-6">
        <NavLink to="/" className="flex items-center gap-2 mr-4">
          <span className="text-emerald-400 font-mono font-semibold text-lg tracking-tight">LOOM</span>
          <span className="text-muted text-xs hidden sm:block">self-improving orchestrator</span>
        </NavLink>
        <NavLink to="/" end className={cls}>Dashboard</NavLink>
        <NavLink to="/agents" className={cls}>Agent Pool</NavLink>
      </div>
    </nav>
  )
}

export default function App() {
  return (
    <BrowserRouter>
      <Nav />
      <main className="pt-14 min-h-screen">
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/sprint/:id" element={<SprintDetail />} />
          <Route path="/agents" element={<Agents />} />
        </Routes>
      </main>
    </BrowserRouter>
  )
}
