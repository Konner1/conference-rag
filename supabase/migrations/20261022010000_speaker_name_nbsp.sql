-- The scraped speaker names mix normal spaces and non-breaking spaces (U+00A0),
-- so the same person could appear twice in the dropdown. Normalize all
-- whitespace to single regular spaces when computing speaker_name.

DROP INDEX IF EXISTS public.paragraph_embeddings_speaker_name_idx;
ALTER TABLE public.paragraph_embeddings DROP COLUMN speaker_name;

ALTER TABLE public.paragraph_embeddings
    ADD COLUMN speaker_name TEXT GENERATED ALWAYS AS (
        btrim(regexp_replace(
            regexp_replace(
                replace(speaker, chr(160), ' '),   -- non-breaking space -> space
                '^(By|Presented by)\s+((Elder|President|Sister|Brother|Bishop)\s+)?',
                '',
                'i'
            ),
            '\s+', ' ', 'g'                        -- collapse runs of whitespace
        ))
    ) STORED;

CREATE INDEX paragraph_embeddings_speaker_name_idx
    ON public.paragraph_embeddings (speaker_name);
