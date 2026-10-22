-- Retention: keep append-only tables from growing without bound.
--   page_views      is writable by anyone (even logged-out), so cap its history.
--   api_rate_limits only needs the current window; old windows are dead weight.

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'purge-old-page-views',
    '17 3 * * *',                       -- daily at 03:17 UTC
    $$DELETE FROM public.page_views WHERE visited_at < now() - interval '30 days'$$
);

SELECT cron.schedule(
    'purge-old-rate-limit-windows',
    '41 * * * *',                       -- hourly at :41
    $$DELETE FROM public.api_rate_limits WHERE window_start < now() - interval '1 day'$$
);
