-- Topic filter: talks are tagged with topics in a separate table (instead of a
-- column on paragraph_embeddings) so tagging never rewrites the big vector table.

CREATE TABLE public.talk_topics (
    talk_id UUID NOT NULL,
    topic   TEXT NOT NULL,
    score   REAL NOT NULL,           -- cosine similarity between talk and topic
    PRIMARY KEY (talk_id, topic)
);

-- "all talks for this topic" (dropdown counts + filtering)
CREATE INDEX talk_topics_topic_idx ON public.talk_topics (topic, talk_id);

ALTER TABLE public.talk_topics ENABLE ROW LEVEL SECURITY;

-- Same model as paragraph_embeddings: logged-in users read, only service_role writes.
CREATE POLICY "Allow authenticated users to read"
    ON public.talk_topics FOR SELECT
    TO authenticated
    USING (true);

CREATE OR REPLACE FUNCTION public.list_topics()
RETURNS TABLE (topic text, talk_count bigint)
LANGUAGE sql STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT tt.topic, count(*) AS talk_count
    FROM public.talk_topics tt
    GROUP BY tt.topic
    ORDER BY tt.topic;
$$;

-- match_paragraphs gains an optional topic filter next to the speaker filter.
DROP FUNCTION IF EXISTS public.match_paragraphs(vector, int, text);

CREATE OR REPLACE FUNCTION public.match_paragraphs(
    query_embedding vector(1536),
    match_count int DEFAULT 20,
    filter_speaker text DEFAULT NULL,
    filter_topic text DEFAULT NULL
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
LANGUAGE plpgsql STABLE
SECURITY INVOKER
SET search_path = public, extensions
AS $$
#variable_conflict use_column
BEGIN
    -- An HNSW index returns its nearest ~40 candidates BEFORE the WHERE runs, so a
    -- selective filter can leave almost nothing. Iterative scan keeps walking the
    -- graph until enough rows pass the filter. Set here with set_config (local to
    -- the transaction) because a function-level SET clause is rejected for the
    -- restricted role the Supabase CLI uses to run migrations.
    PERFORM set_config('hnsw.iterative_scan', 'relaxed_order', true);

    RETURN QUERY
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
      AND (filter_topic IS NULL OR EXISTS (
            SELECT 1 FROM public.talk_topics tt
            WHERE tt.talk_id = pe.talk_id AND tt.topic = filter_topic))
    ORDER BY pe.embedding <=> query_embedding
    LIMIT least(match_count, 100);
END;
$$;
