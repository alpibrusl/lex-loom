import type { SprintStat, SprintStatus, TrailEvent, Agent, AgentDetail, SprintResult, DigestData, ProviderInfo, CompanyStat, CompanyDetail } from './types';

async function get<T>(path: string): Promise<T> {
  const r = await fetch(path);
  if (!r.ok) throw new Error(`${r.status} ${path}`);
  return r.json();
}

export async function getSeries(): Promise<{ series: SprintStat[] }> {
  return get('/api/series');
}

export async function getSprintStatus(id: string): Promise<SprintStatus> {
  return get(`/api/sprints/${id}/status`);
}

export async function getSprintTrail(id: string): Promise<{ sprint_id: string; events: TrailEvent[] }> {
  return get(`/api/sprints/${id}/trail`);
}

export async function getSprintDigest(id: string): Promise<DigestData> {
  return get(`/api/sprints/${id}/digest`);
}

export async function getArtifact(sprintId: string, hash: string): Promise<{ hash: string; content: string }> {
  return get(`/api/sprints/${sprintId}/artifact/${hash}`);
}

export async function getAgents(): Promise<{ agents: Agent[] }> {
  return get('/api/agents');
}

export async function getAgent(id: string): Promise<AgentDetail> {
  return get(`/api/agents/${id}`);
}

export async function runSprint(req: {
  sprint_id: string;
  request: string;
  model: string;
}): Promise<SprintResult> {
  const r = await fetch('/api/sprints', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  });
  return r.json();
}

export async function getProviders(): Promise<ProviderInfo> {
  return get('/api/providers');
}

export async function createAgent(req: {
  id: string;
  role: string;
  system_prompt: string;
  attestation_count?: number;
  model_name?: string;
}): Promise<{ id: string; role: string; created: boolean }> {
  const r = await fetch('/api/agents', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export async function getCompanies(): Promise<{ companies: CompanyStat[] }> {
  return get('/api/companies');
}

export async function getCompanyDetail(id: string): Promise<CompanyDetail> {
  return get(`/api/companies/${id}`);
}
