-- PostgreSQL schema for chessbuddy persistence layer
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;

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
    ingestion_batch UUID REFERENCES ingestion_batches(batch_id),
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (white_id, black_id, game_date, round, source_pgn)
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
