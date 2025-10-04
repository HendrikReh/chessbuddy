BEGIN;

-- Rename legacy table if present
DO $$
BEGIN
  IF to_regclass('public.game_patterns_legacy') IS NULL
     AND to_regclass('public.game_themes') IS NOT NULL THEN
    ALTER TABLE game_themes RENAME TO game_patterns_legacy;
  END IF;
END
$$;

-- Pattern catalog (registry)
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

-- Pattern detections table
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

-- Validation table for manual QA
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

-- ECO indexes to speed opening filters
CREATE INDEX IF NOT EXISTS idx_games_eco_kings_indian
    ON games (eco_code)
    WHERE eco_code LIKE 'E6%' OR eco_code LIKE 'E7%' OR eco_code LIKE 'E8%' OR eco_code LIKE 'E9%';

CREATE INDEX IF NOT EXISTS idx_games_eco_white_black_elo
    ON games (eco_code, white_elo DESC NULLS LAST, black_elo DESC NULLS LAST);

-- Seed canonical patterns
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

-- Optional: migrate legacy queenside flag if present
INSERT INTO pattern_detections (
    game_id, pattern_id, detected_by_color, success, confidence,
    start_ply, end_ply, outcome, metadata)
SELECT
    game_id,
    'queenside_majority_attack',
    'white',
    queenside_majority_success,
    CASE WHEN queenside_majority_success THEN 0.8 ELSE 0.4 END,
    NULL,
    NULL,
    NULL,
    jsonb_build_object('legacy', true)
FROM game_patterns_legacy
ON CONFLICT (game_id, pattern_id, detected_by_color) DO NOTHING;

COMMIT;
