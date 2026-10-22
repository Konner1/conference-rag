-- Scale / security pass.
--
-- 1. Least-privilege table grants. Supabase grants anon/authenticated every
--    privilege on new public tables and relies on RLS alone. RLS does not apply to
--    TRUNCATE, so revoke everything the app does not need (defense in depth).
-- 2. Function execute rights: only logged-in users run the search/list functions.
-- 3. Per-user rate limiting for the Edge Functions (protects the OpenAI bill).

-- ---------------------------------------------------------------- 1. grants
REVOKE ALL ON public.paragraph_embeddings FROM anon, authenticated;
GRANT SELECT ON public.paragraph_embeddings TO authenticated;

REVOKE ALL ON public.talk_topics FROM anon, authenticated;
GRANT SELECT ON public.talk_topics TO authenticated;

-- page_views stays public by design (RLS contrast demo): read + insert only.
REVOKE ALL ON public.page_views FROM anon, authenticated;
GRANT SELECT, INSERT ON public.page_views TO anon, authenticated;

-- ------------------------------------------------------------ 2. functions
REVOKE EXECUTE ON FUNCTION public.match_paragraphs(vector, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.match_paragraphs(vector, int, text, text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.list_speakers() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_speakers() TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.list_topics() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_topics() TO authenticated, service_role;

-- --------------------------------------------------------- 3. rate limiting
-- Fixed-window counter: one row per (user, function, window). A burst straddling
-- a window boundary can briefly reach up to 2x the limit; fine for cost control.
CREATE TABLE public.api_rate_limits (
    user_id      UUID        NOT NULL,
    fn           TEXT        NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    hits         INTEGER     NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, fn, window_start)
);

CREATE INDEX api_rate_limits_window_idx ON public.api_rate_limits (window_start);

-- RLS on with no policies = nobody but service_role can touch it.
ALTER TABLE public.api_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.api_rate_limits FROM anon, authenticated;

-- Records one call and says whether it is still within the limit. Atomic: the
-- upsert takes a row lock, so concurrent requests cannot both slip under it.
CREATE OR REPLACE FUNCTION public.rate_limit_hit(
    p_user UUID,
    p_fn TEXT,
    p_limit INT,
    p_window_seconds INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    w TIMESTAMPTZ := to_timestamp(floor(extract(epoch FROM now()) / p_window_seconds) * p_window_seconds);
    h INT;
BEGIN
    INSERT INTO public.api_rate_limits AS r (user_id, fn, window_start, hits)
    VALUES (p_user, p_fn, w, 1)
    ON CONFLICT (user_id, fn, window_start) DO UPDATE SET hits = r.hits + 1
    RETURNING r.hits INTO h;

    RETURN h <= p_limit;
END;
$$;

-- SECURITY DEFINER runs with the owner's rights, so it must not be callable by
-- the public: otherwise anyone could burn another user's quota.
REVOKE EXECUTE ON FUNCTION public.rate_limit_hit(UUID, TEXT, INT, INT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.rate_limit_hit(UUID, TEXT, INT, INT) TO service_role;
