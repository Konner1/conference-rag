-- Conference RAG schema (adapted from scripts/01_create_schema.py)

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================
-- sentence_embeddings: protected content (auth-only reads)
-- ============================================
CREATE TABLE IF NOT EXISTS public.sentence_embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    talk_id UUID NOT NULL,
    title TEXT NOT NULL,
    speaker TEXT,
    calling TEXT,
    year INTEGER,
    season TEXT,
    url TEXT,
    sentence_num INTEGER,
    text TEXT NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS sentence_embeddings_talk_id_idx
    ON public.sentence_embeddings (talk_id);

-- Scale: approximate nearest-neighbour index so similarity search stays fast
-- at millions of rows (without it every query scans the whole table).
CREATE INDEX IF NOT EXISTS sentence_embeddings_embedding_hnsw_idx
    ON public.sentence_embeddings USING hnsw (embedding vector_cosine_ops);

-- Scale: trigram index lets keyword ILIKE '%term%' use an index.
CREATE INDEX IF NOT EXISTS sentence_embeddings_text_trgm_idx
    ON public.sentence_embeddings USING gin (text gin_trgm_ops);

ALTER TABLE public.sentence_embeddings ENABLE ROW LEVEL SECURITY;

-- Only a SELECT policy exists: with RLS on and no INSERT/UPDATE/DELETE policy,
-- anon and authenticated users cannot write. Only service_role (bypasses RLS) can.
DROP POLICY IF EXISTS "Allow authenticated users to read" ON public.sentence_embeddings;
CREATE POLICY "Allow authenticated users to read"
    ON public.sentence_embeddings FOR SELECT
    TO authenticated
    USING (true);

-- ============================================
-- page_views: intentionally public (RLS contrast demo)
-- ============================================
CREATE TABLE IF NOT EXISTS public.page_views (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visited_at TIMESTAMPTZ DEFAULT NOW(),
    page_url TEXT CHECK (char_length(page_url) <= 2048),
    user_agent TEXT CHECK (char_length(user_agent) <= 1024)
);

CREATE INDEX IF NOT EXISTS page_views_visited_at_idx
    ON public.page_views (visited_at DESC);

ALTER TABLE public.page_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow public inserts" ON public.page_views;
CREATE POLICY "Allow public inserts"
    ON public.page_views FOR INSERT
    TO anon, authenticated
    WITH CHECK (true);

DROP POLICY IF EXISTS "Allow public reads" ON public.page_views;
CREATE POLICY "Allow public reads"
    ON public.page_views FOR SELECT
    TO anon, authenticated
    USING (true);

-- ============================================
-- match_sentences: vector similarity search
-- ============================================
-- SECURITY INVOKER (the default) means the caller's RLS policies apply, so
-- anon callers get zero rows. search_path is pinned for safety.
CREATE OR REPLACE FUNCTION public.match_sentences(
    query_embedding vector(1536),
    match_count int DEFAULT 20
)
RETURNS TABLE (
    id uuid,
    talk_id uuid,
    title text,
    speaker text,
    text text,
    similarity float
)
LANGUAGE sql STABLE
SECURITY INVOKER
SET search_path = public, extensions
AS $$
    SELECT
        se.id,
        se.talk_id,
        se.title,
        se.speaker,
        se.text,
        1 - (se.embedding <=> query_embedding) AS similarity
    FROM public.sentence_embeddings se
    WHERE se.embedding IS NOT NULL
    ORDER BY se.embedding <=> query_embedding
    LIMIT least(match_count, 100);
$$;
