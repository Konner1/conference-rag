-- Speaker filter: normalized speaker name + dropdown source + filtered search.

-- "By Elder Gary E. Stevenson" / "By President Russell M. Nelson" /
-- "Presented by President Henry B. Eyring"  ->  the bare name. The same person
-- can appear under different titles over the years, so this groups them.
-- Generated + stored: Postgres keeps it in sync, and it can be indexed.
ALTER TABLE public.paragraph_embeddings
    ADD COLUMN speaker_name TEXT GENERATED ALWAYS AS (
        btrim(regexp_replace(
            speaker,
            '^(By|Presented by)\s+((Elder|President|Sister|Brother|Bishop)\s+)?',
            '',
            'i'
        ))
    ) STORED;

CREATE INDEX paragraph_embeddings_speaker_name_idx
    ON public.paragraph_embeddings (speaker_name);

-- Feeds the dropdown. SECURITY INVOKER, so RLS applies: anon gets nothing.
CREATE OR REPLACE FUNCTION public.list_speakers()
RETURNS TABLE (speaker_name text, talk_count bigint)
LANGUAGE sql STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT pe.speaker_name, count(DISTINCT pe.talk_id) AS talk_count
    FROM public.paragraph_embeddings pe
    WHERE pe.speaker_name IS NOT NULL AND pe.speaker_name <> ''
    GROUP BY pe.speaker_name
    ORDER BY pe.speaker_name;
$$;

-- Replace match_paragraphs with a version that takes an optional speaker.
DROP FUNCTION IF EXISTS public.match_paragraphs(vector, int);

CREATE OR REPLACE FUNCTION public.match_paragraphs(
    query_embedding vector(1536),
    match_count int DEFAULT 20,
    filter_speaker text DEFAULT NULL
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
-- An HNSW index returns its nearest ~40 candidates BEFORE the WHERE runs, so a
-- selective filter can leave almost nothing. Iterative scan keeps walking the
-- graph until enough rows pass the filter.
SET hnsw.iterative_scan = relaxed_order
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
      AND (filter_speaker IS NULL OR pe.speaker_name = filter_speaker)
    ORDER BY pe.embedding <=> query_embedding
    LIMIT least(match_count, 100);
$$;
