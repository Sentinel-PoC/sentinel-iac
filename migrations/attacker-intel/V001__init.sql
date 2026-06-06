-- V001__init.sql — Attacker Intelligence DB schema initialization
-- [OPS-566] Plan G' — pgvector PostgreSQL attacker intel store
-- Applied by: ansible/roles/postgres-attacker-intel/tasks/migrate.yml
-- Idempotent: all CREATE statements use IF NOT EXISTS.

-- ---------------------------------------------------------------------------
-- Extension: pgvector
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector;

-- Verify extension loaded (will raise if pgvector is not available)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
    RAISE EXCEPTION 'pgvector extension failed to install';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Table: attackers
-- Core attacker profile record. One row per distinct attacker identity.
-- embedding column holds a 768-dim float4 vector for semantic similarity
-- queries (e.g. "find attackers behaving like this one").
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attackers (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    asn         INTEGER,
    geo         JSONB,
    risk_score  REAL        NOT NULL DEFAULT 0.0,
    embedding   vector(768),
    notes       JSONB       NOT NULL DEFAULT '{}'
);

COMMENT ON TABLE  attackers              IS 'Per-attacker profiles; one row per distinct attacker identity (OPS-566)';
COMMENT ON COLUMN attackers.embedding    IS '768-dim embedding for semantic similarity via pgvector <-> operator';
COMMENT ON COLUMN attackers.risk_score   IS 'Composite risk score 0.0–1.0; updated by AI orchestrator (OPS-577)';
COMMENT ON COLUMN attackers.geo          IS 'GeoIP metadata: {country, city, lat, lon}';

-- ---------------------------------------------------------------------------
-- Table: observations
-- Individual event records associated with an attacker.
-- Foreign key ON DELETE CASCADE keeps orphan-free invariant.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS observations (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    attacker_id UUID        NOT NULL REFERENCES attackers(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    src_ip      INET,
    dst_port    INTEGER     CHECK (dst_port BETWEEN 0 AND 65535),
    signature   TEXT,
    raw_event   JSONB       NOT NULL DEFAULT '{}'
);

COMMENT ON TABLE  observations              IS 'Individual sensor events attributed to an attacker';
COMMENT ON COLUMN observations.attacker_id  IS 'FK → attackers.id; CASCADE deletes keep referential integrity';
COMMENT ON COLUMN observations.raw_event    IS 'Full raw event payload (Wazuh alert, Suricata eve, etc.)';

-- ---------------------------------------------------------------------------
-- Table: attacker_relationships
-- Directed edges in the attacker graph.
-- a_id → b_id with relation_type (e.g. "same_asn", "similar_ttps").
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attacker_relationships (
    id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    a_id          UUID    NOT NULL REFERENCES attackers(id) ON DELETE CASCADE,
    b_id          UUID    NOT NULL REFERENCES attackers(id) ON DELETE CASCADE,
    relation_type TEXT    NOT NULL,
    confidence    REAL    NOT NULL DEFAULT 0.0 CHECK (confidence BETWEEN 0.0 AND 1.0),
    CONSTRAINT no_self_loop CHECK (a_id <> b_id)
);

COMMENT ON TABLE  attacker_relationships               IS 'Attacker-to-attacker relationship graph edges';
COMMENT ON COLUMN attacker_relationships.relation_type IS 'Edge label: same_asn | similar_ttps | same_campaign | ...';
COMMENT ON COLUMN attacker_relationships.confidence    IS 'Confidence score 0.0–1.0 for the inferred relationship';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Observations: frequent query patterns
CREATE INDEX IF NOT EXISTS idx_observations_attacker_id
    ON observations (attacker_id);

CREATE INDEX IF NOT EXISTS idx_observations_ts
    ON observations (ts DESC);

CREATE INDEX IF NOT EXISTS idx_observations_src_ip
    ON observations (src_ip);

-- Attackers: range and sort access
CREATE INDEX IF NOT EXISTS idx_attackers_risk_score
    ON attackers (risk_score DESC);

CREATE INDEX IF NOT EXISTS idx_attackers_last_seen
    ON attackers (last_seen DESC);

-- Relationships: graph traversal
CREATE INDEX IF NOT EXISTS idx_attacker_relationships_a_id
    ON attacker_relationships (a_id);

CREATE INDEX IF NOT EXISTS idx_attacker_relationships_b_id
    ON attacker_relationships (b_id);

-- pgvector IVFFlat index for approximate nearest-neighbor embedding search.
-- lists=100 is appropriate for initial dataset; rebuild with REINDEX after
-- data load grows beyond ~1M rows (pgvector recommendation: lists ≈ sqrt(n)).
-- cosine distance (<=>): appropriate for normalized embedding vectors.
CREATE INDEX IF NOT EXISTS idx_attackers_embedding_cosine
    ON attackers USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
