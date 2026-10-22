-- Switch chunking granularity from sentences to paragraphs.
-- sentence_embeddings was still empty, so it is dropped (its indexes and
-- policies go with it) and replaced by paragraph_embeddings.

DROP FUNCTION IF EXISTS public.match_sentences(vector, int);
DROP TABLE IF EXISTS public.sentence_embeddings;

CREATE TABLE public.paragraph_embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    talk_id UUID NOT NULL,
    title TEXT NOT NULL,
    speaker TEXT,
    calling TEXT,
    year INTEGER,
    season TEXT,
    url TEXT,
    paragraph_num INTEGER,
    text TEXT NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Group/fetch all paragraphs of a talk in reading order.
CREATE INDEX paragraph_embeddings_talk_para_idx
    ON public.paragraph_embeddings (talk_id, paragraph_num);

-- Approximate nearest-neighbour index for cosine similarity search.
CREATE INDEX paragraph_embeddings_embedding_hnsw_idx
    ON public.paragraph_embeddings USING hnsw (embedding vector_cosine_ops);

-- Trigram index so keyword ILIKE '%term%' can use an index.
CREATE INDEX paragraph_embeddings_text_trgm_idx
    ON public.paragraph_embeddings USING gin (text gin_trgm_ops);

ALTER TABLE public.paragraph_embeddings ENABLE ROW LEVEL SECURITY;

-- Read-only for logged-in users. No write policies => only service_role can write.
CREATE POLICY "Allow authenticated users to read"
    ON public.paragraph_embeddings FOR SELECT
    TO authenticated
    USING (true);

-- SECURITY INVOKER: caller's RLS applies, so anon callers get zero rows.
CREATE OR REPLACE FUNCTION public.match_paragraphs(
    query_embedding vector(1536),
    match_count int DEFAULT 20
)
RETURNS TABLE (
    id uuid,
    talk_id uuid,
    title text,
    speaker text,
    url text,
    paragraph_num int,
    text text,
    similarity float
)
LANGUAGE sql STABLE
SECURITY INVOKER
SET search_path = public, extensions
AS $$
    SELECT
        pe.id,
        pe.talk_id,
        pe.title,
        pe.speaker,
        pe.url,
        pe.paragraph_num,
        pe.text,
        1 - (pe.embedding <=> query_embedding) AS similarity
    FROM public.paragraph_embeddings pe
    WHERE pe.embedding IS NOT NULL
    ORDER BY pe.embedding <=> query_embedding
    LIMIT least(match_count, 100);
$$;
