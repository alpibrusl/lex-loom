export interface SprintStat {
  sprint_id: string;
  ts: string;
  success: boolean;
  qa_accepted: boolean;
  qa_verdict: 'PASS' | 'FAIL' | '';
}

export interface PhaseTransition {
  from: string;
  to: string;
  evidence: string;
  ts: string;
}

export interface TrailEvent {
  ts: string;
  event_kind: string;
  data_json: string;
}

export interface Agent {
  id: string;
  role: string;
  model_name: string;
  domain_tags: string[];
  attestation_count: number;
  created_at: string;
}

export interface AgentDetail extends Agent {
  system_prompt: string;
}

export interface SprintStatus {
  sprint_id: string;
  transitions: PhaseTransition[];
  trail_count: number;
}

export interface SprintResult {
  sprint_id: string;
  success: boolean;
  summary: string;
}

export interface TightenedSpec {
  node_role: string;
  spec_src: string;
  reason: string;
}

export interface DigestData {
  sprint_id: string;
  summary: string;
  specs: TightenedSpec[];
  has_seed_graph: boolean;
}

export interface ProviderInfo {
  active: string;
  default_model: string;
  configured: string[];
  models: Record<string, string[]>;
}

export interface CompanyStat {
  id: string;
  goal: string;
  stage: string;
  iterations: number;
  open_incidents: number;
  escalated_count: number;
  spend_cents: number;
}

export interface OperateMetrics {
  open_incidents: number;
  resolved_count: number;
  escalated_count: number;
  verified_effects: number;
  hit_rate_pct: number;
  hit_rate_trend: string;
  avg_evidence_cost_milli: number;
}

export interface CompanyIterationRow {
  idx: number;
  sprint_id: string;
  status: string;
  goal: string;
}

export interface CompanyContact {
  oracle: string;
  kind: string;
  name: string;
  contact: string;
  note: string;
}

export interface CompanyDetail {
  id: string;
  goal: string;
  stage: string;
  max_iterations: number;
  stop_when: string;
  spend_cents: number;
  latest_sprint_id: string;
  live_url: string;
  live_status: 'up' | 'down' | 'unknown';
  iterations: CompanyIterationRow[];
  shipped_summary: string;
  backlog_summary: string;
  operate_metrics: OperateMetrics;
  operate_signals: string;
  escalations: string[];
  contacts: CompanyContact[];
  decisions: string[];
  stage_transitions: string[];
}
