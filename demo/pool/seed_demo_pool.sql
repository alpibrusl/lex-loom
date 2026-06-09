-- Seed demo-specific pool agents for "The Sprint That Fixes Itself" demo.
-- Run once against the demo DB before starting sprints.
--
-- High attestation_count (100) ensures these agents win Cast scoring over
-- any default agents that have 0 attestations.
--
-- Domain tags are matched case-sensitively against the sprint REQUEST string.

INSERT OR REPLACE INTO agent_pool
  (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at)
VALUES
  -- Sprint 1 Build: bad code first, good code on retry (sentinel-based)
  (
    'demo-build-registration',
    'build',
    'Demo Build agent for user registration API.',
    'proc:./demo/agents/build_registration.sh',
    '["registration","users","signup"]',
    100,
    datetime('now')
  ),
  -- Sprint 2 Build: always returns invite_api.py which contains EMAIL_REGEX
  (
    'demo-build-invite',
    'build',
    'Demo Build agent for team invite API.',
    'proc:./demo/agents/build_invite.sh',
    '["invite","team","invitation"]',
    100,
    datetime('now')
  ),
  -- Scribe: deterministic JSON digest so the learning loop is reliable
  (
    'demo-scribe',
    'scribe',
    'Demo Scribe agent — emits a fixed Sprint 1 digest JSON.',
    'proc:./demo/agents/scribe.sh',
    '["registration","invite","demo"]',
    100,
    datetime('now')
  );
