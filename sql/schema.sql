-- PostgreSQL schema for chessbuddy persistence layer
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS players (
    player_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name TEXT NOT NULL,
    fide_id TEXT UNIQUE,
    full_name_key TEXT GENERATED ALWAYS AS (lower(full_name)) STORED UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS player_ratings (
    player_id UUID NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    rating_date DATE NOT NULL,
    standard_elo SMALLINT,
    rapid_elo SMALLINT,
    blitz_elo SMALLINT,
    PRIMARY KEY (player_id, rating_date)
);

CREATE TABLE IF NOT EXISTS ingestion_batches (
    batch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_path TEXT NOT NULL,
    label TEXT NOT NULL,
    checksum TEXT NOT NULL UNIQUE,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS games (
    game_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event TEXT,
    site TEXT,
    game_date DATE,
    round TEXT,
    eco_code TEXT,
    opening_name TEXT,
    white_id UUID NOT NULL REFERENCES players(player_id),
    black_id UUID NOT NULL REFERENCES players(player_id),
    white_elo SMALLINT,
    black_elo SMALLINT,
    result TEXT NOT NULL,
    termination TEXT,
    source_pgn TEXT NOT NULL,
    pgn_hash TEXT GENERATED ALWAYS AS (encode(digest(source_pgn, 'sha256'), 'hex')) STORED,
    ingestion_batch UUID REFERENCES ingestion_batches(batch_id),
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (white_id, black_id, game_date, round, pgn_hash)
);

CREATE INDEX IF NOT EXISTS idx_games_eco_date ON games (eco_code, game_date);
CREATE INDEX IF NOT EXISTS idx_games_white_elo ON games (white_elo DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_games_black_elo ON games (black_elo DESC NULLS LAST);

CREATE TABLE IF NOT EXISTS fens (
    fen_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    fen_text TEXT NOT NULL UNIQUE,
    side_to_move CHAR(1) NOT NULL,
    castling_rights TEXT NOT NULL,
    en_passant_file TEXT,
    material_signature TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS fen_embeddings (
    fen_id UUID PRIMARY KEY REFERENCES fens(fen_id) ON DELETE CASCADE,
    embedding vector(768) NOT NULL,
    embedding_version TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (vector_dims(embedding) = 768)
);

CREATE TABLE IF NOT EXISTS games_positions (
    game_id UUID NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
    ply_number INTEGER NOT NULL,
    fen_id UUID NOT NULL REFERENCES fens(fen_id) ON DELETE CASCADE,
    side_to_move CHAR(1) NOT NULL,
    san TEXT NOT NULL,
    uci TEXT,
    fen_before TEXT NOT NULL,
    fen_after TEXT NOT NULL,
    clock NUMERIC,
    eval_cp INTEGER,
    is_capture BOOLEAN NOT NULL DEFAULT false,
    is_check BOOLEAN NOT NULL DEFAULT false,
    is_mate BOOLEAN NOT NULL DEFAULT false,
    motif_flags TEXT[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (game_id, ply_number)
);

CREATE INDEX IF NOT EXISTS idx_games_positions_fen ON games_positions (fen_id);
CREATE INDEX IF NOT EXISTS idx_games_positions_motifs ON games_positions USING gin (motif_flags);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_latest_ratings AS
SELECT DISTINCT ON (pr.player_id)
    pr.player_id,
    pr.rating_date,
    pr.standard_elo
FROM player_ratings pr
ORDER BY pr.player_id, pr.rating_date DESC;

CREATE TABLE IF NOT EXISTS game_themes (
    game_id UUID PRIMARY KEY REFERENCES games(game_id) ON DELETE CASCADE,
    queenside_majority_success BOOLEAN NOT NULL DEFAULT false,
    motifs JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_game_themes_queenside ON game_themes (queenside_majority_success);

CREATE TABLE IF NOT EXISTS search_documents (
    document_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    content TEXT NOT NULL,
    embedding vector(1536) NOT NULL,
    model TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (entity_type, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_search_documents_entity ON search_documents (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_search_documents_updated ON search_documents (updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_search_documents_embedding ON search_documents USING ivfflat (embedding vector_l2_ops) WITH (lists = 500);

-- Pattern catalog and detections
CREATE TABLE IF NOT EXISTS pattern_catalog (
    pattern_id TEXT PRIMARY KEY,
    pattern_name TEXT NOT NULL,
    pattern_type TEXT NOT NULL CHECK (pattern_type IN ('strategic', 'tactical', 'endgame', 'opening_trap')),
    description TEXT,
    detector_module TEXT NOT NULL,
    success_criteria JSONB,
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pattern_detections (
    detection_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    game_id UUID NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
    pattern_id TEXT NOT NULL REFERENCES pattern_catalog(pattern_id),
    detected_by_color TEXT NOT NULL CHECK (detected_by_color IN ('white', 'black')),
    success BOOLEAN NOT NULL,
    confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
    start_ply INT,
    end_ply INT,
    outcome TEXT CHECK (outcome IN ('victory', 'draw_advantage', 'draw_neutral', 'defeat')),
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (game_id, pattern_id, detected_by_color)
);

CREATE INDEX IF NOT EXISTS idx_pattern_detections_game ON pattern_detections (game_id);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_pattern ON pattern_detections (pattern_id, success);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_color ON pattern_detections (detected_by_color, success);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_confidence ON pattern_detections (confidence DESC);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_metadata ON pattern_detections USING gin (metadata);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_created ON pattern_detections (created_at DESC);

CREATE TABLE IF NOT EXISTS pattern_validation (
    validation_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    detection_id UUID NOT NULL REFERENCES pattern_detections(detection_id) ON DELETE CASCADE,
    manually_verified BOOLEAN,
    verified_by TEXT,
    verified_at TIMESTAMPTZ,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pattern_validation_detection ON pattern_validation (detection_id);
CREATE INDEX IF NOT EXISTS idx_pattern_validation_unverified
    ON pattern_validation (manually_verified, created_at DESC)
    WHERE manually_verified IS NULL OR manually_verified = false;

CREATE INDEX IF NOT EXISTS idx_games_eco_kings_indian
    ON games (eco_code)
    WHERE eco_code LIKE 'E6%' OR eco_code LIKE 'E7%' OR eco_code LIKE 'E8%' OR eco_code LIKE 'E9%';

CREATE INDEX IF NOT EXISTS idx_games_eco_white_black_elo
    ON games (eco_code, white_elo DESC NULLS LAST, black_elo DESC NULLS LAST);

INSERT INTO pattern_catalog (pattern_id, pattern_name, pattern_type, detector_module, description)
VALUES
    ('queenside_majority_attack', 'Queenside Majority Attack', 'strategic',
     'Strategic_patterns.Queenside_attack',
     'Pawn majority on queenside (files a-c) advanced to create passed pawns or material gain'),
    ('minority_attack', 'Minority Attack', 'strategic',
     'Strategic_patterns.Minority_attack',
     'Pawn minority pressing opponent majority to create weaknesses'),
    ('greek_gift_sacrifice', 'Greek Gift Sacrifice', 'tactical',
     'Tactical_patterns.Greek_gift',
     'Bxh7+/Bxh2+ sacrifice to expose the king'),
    ('lucena_position', 'Lucena Position', 'endgame',
     'Endgame_patterns.Lucena',
     'Winning rook endgame technique with a bridge'),
    ('philidor_position', 'Philidor Position', 'endgame',
     'Endgame_patterns.Philidor',
     'Defensive rook endgame drawing technique (rook on sixth rank)')
ON CONFLICT (pattern_id) DO NOTHING;
