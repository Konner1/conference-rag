"""
Step 5b: Resume Embedding Import
=================================
05_update_embeddings.py truncates the table and re-inserts everything. With an
HNSW index on the embedding column, each insert gets slower as the index grows,
and large batches can exceed Supabase's 8s API statement timeout (error 57014).

This script inserts only the rows that are missing from the database, in small
batches with retries, so it is safe to re-run until everything is loaded.

Usage:
    python scripts/05b_resume_embeddings.py
"""

import json
import os
import time

from supabase import create_client
from tqdm import tqdm


INPUT_FILE = os.path.join('scripts', 'output', 'paragraphs_with_embeddings.json')
BATCH_SIZE = 20
MAX_RETRIES = 4
PAGE_SIZE = 1000


def main():
    with open('config.public.json') as f:
        public_config = json.load(f)
    with open('config.secret.json') as f:
        secrets = json.load(f)
    client = create_client(public_config['SUPABASE_URL'], secrets['SUPABASE_SERVICE_KEY'])

    with open(INPUT_FILE, 'r', encoding='utf-8') as f:
        records = json.load(f)

    # Which (talk_id, paragraph_num) pairs are already in the database?
    existing = set()
    start = 0
    while True:
        page = (client.table('paragraph_embeddings')
                .select('talk_id, paragraph_num')
                .order('talk_id').order('paragraph_num')
                .range(start, start + PAGE_SIZE - 1).execute().data)
        existing.update((r['talk_id'], r['paragraph_num']) for r in page)
        if len(page) < PAGE_SIZE:
            break
        start += PAGE_SIZE

    missing = [r for r in records if (r['talk_id'], r['paragraph_num']) not in existing]
    print(f"File: {len(records):,} | in database: {len(existing):,} | missing: {len(missing):,}")

    failed = 0
    for i in tqdm(range(0, len(missing), BATCH_SIZE), desc="Inserting"):
        batch = missing[i:i + BATCH_SIZE]
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                client.table('paragraph_embeddings').insert(batch).execute()
                break
            except Exception as e:
                if attempt == MAX_RETRIES:
                    print(f"\n   ❌ Gave up on batch at {i}: {e}")
                    failed += len(batch)
                else:
                    time.sleep(2 * attempt)
        time.sleep(0.05)

    total = client.table('paragraph_embeddings').select('id', count='exact').limit(1).execute().count
    print(f"\n✅ Done. Rows in database: {total:,} (failed: {failed})")


if __name__ == '__main__':
    main()
