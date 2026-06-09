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
