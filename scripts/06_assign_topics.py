"""
Step 6 (extension): Tag Talks With Topics
==========================================
Uses embeddings to tag each talk with up to MAX_TOPICS_PER_TALK topics:

  1. Embed a short description of every topic (OpenAI, a few cents).
  2. Average each talk's paragraph vectors into one "talk vector".
  3. Cosine similarity between each talk vector and each topic vector.
  4. Turn each topic's similarities into z-scores across all talks, so a talk is
     tagged only when it is unusually close to a topic *compared with other talks*.
     (Every conference talk is broadly "gospel-like", so raw similarities all sit
     around 0.5 and an absolute cutoff tags everything with the general topics.)
  5. Write the tags to the talk_topics table (only with --apply).

Usage:
    python scripts/06_assign_topics.py            # dry run: shows scores, writes nothing
    python scripts/06_assign_topics.py --apply    # replaces talk_topics in Supabase

Input:
    scripts/output/paragraphs_with_embeddings.json  — from Step 4
"""

import json
import math
import os
import sys
from collections import Counter, defaultdict

from openai import OpenAI
from supabase import create_client


INPUT_FILE = os.path.join('scripts', 'output', 'paragraphs_with_embeddings.json')
OUTPUT_FILE = os.path.join('scripts', 'output', 'talk_topics.json')
MODEL = 'text-embedding-3-small'
MIN_Z = 1.0               # standard deviations above the topic's average across talks
MAX_TOPICS_PER_TALK = 3
BATCH_SIZE = 50

# Label shown in the dropdown -> description that gets embedded.
TOPICS = {
    'Faith in Jesus Christ': 'Having faith in Jesus Christ, trusting Him, and following the Savior',
    'Atonement & Forgiveness': "The Savior's Atonement, repentance, and receiving forgiveness",
    'Family & Parenting': 'Marriage, raising children, strengthening the family and the home',
    'Temples & Covenants': 'Temple worship, making and keeping covenants, sealing ordinances',
    'Prayer & Revelation': 'Praying, listening to the Holy Ghost, and receiving personal revelation',
    'Scriptures & Book of Mormon': 'Studying the scriptures and the Book of Mormon',
    'Missionary Work & Sharing the Gospel': 'Missionary service, sharing the gospel, and gathering Israel',
    'Service & Charity': 'Serving others, charity, ministering, and caring for the poor and needy',
    'Hope, Peace & Joy': 'Finding hope, peace, comfort, and joy in life',
    'Trials & Adversity': 'Enduring hardship, suffering, grief, doubt, and challenges',
    'Priesthood & Leadership': 'Priesthood power, authority, and leading in the Church',
    'Prophets & Following Them': 'Living prophets, apostles, and following their counsel',
    'Gratitude & Blessings': 'Counting blessings, thankfulness, and recognizing the hand of God',
    'Divine Identity & Love of God': 'Being a child of God, His love for us, and our divine potential',
    'Sabbath & Worship': 'Keeping the Sabbath day holy, the sacrament, and weekly worship',
    'Youth & Young Adults': 'Counsel to youth and young adults about choices, identity, and the future',
    'Unity & Gathering Together': 'Unity, peacemaking, treating others with kindness, and belonging',
    'Obedience & Discipleship': 'Being a disciple of Christ, obedience, endurance, and daily commitment',
}


def load_config():
    with open('config.public.json') as f:
        public_config = json.load(f)
    with open('config.secret.json') as f:
        secrets = json.load(f)
    return public_config, secrets


def normalize(v):
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def main():
    apply = '--apply' in sys.argv
    public_config, secrets = load_config()

    # 1. Embed the topic descriptions
    openai = OpenAI(api_key=secrets['OPENAI_API_KEY'])
    names = list(TOPICS)
    response = openai.embeddings.create(model=MODEL, input=[TOPICS[n] for n in names])
    topic_vecs = {n: normalize(item.embedding) for n, item in zip(names, response.data)}

    # 2. Average each talk's paragraph vectors
    print('Loading paragraph embeddings...')
    with open(INPUT_FILE, 'r', encoding='utf-8') as f:
        records = json.load(f)
    sums, counts, titles = {}, Counter(), {}
    for r in records:
        t = r['talk_id']
        if t not in sums:
            sums[t] = [0.0] * len(r['embedding'])
            titles[t] = r['title']
        sums[t] = [a + b for a, b in zip(sums[t], r['embedding'])]
        counts[t] += 1
    talk_vecs = {t: normalize(v) for t, v in sums.items()}
    del records
    print(f'   {len(talk_vecs)} talks, {len(names)} topics')

    # 3-4. Score and pick
    sims = {t: {n: dot(tv, topic_vecs[n]) for n in names} for t, tv in talk_vecs.items()}
    stats = {}
    for n in names:
        vals = [sims[t][n] for t in sims]
        mean = sum(vals) / len(vals)
        std = math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals))
        stats[n] = (mean, std)

    rows = []
    per_topic = Counter()
    for t in sims:
        scored = sorted(((((sims[t][n] - stats[n][0]) / stats[n][1]), n) for n in names), reverse=True)
        for z, name in scored[:MAX_TOPICS_PER_TALK]:
            if z >= MIN_Z:
                rows.append({'talk_id': t, 'topic': name, 'score': round(sims[t][name], 4)})
                per_topic[name] += 1

    n = len(sims)
    tagged = len({r['talk_id'] for r in rows})
    print(f'\nTalks with at least one topic: {tagged}/{n} (MIN_Z={MIN_Z}, '
          f'max {MAX_TOPICS_PER_TALK} each)  ->  {len(rows)} tags\n')
    for name, c in per_topic.most_common():
        print(f'   {c:4d}  {name}')

    print('\nSample talks:')
    by_talk = defaultdict(list)
    for r in rows:
        by_talk[r['talk_id']].append(f"{r['topic']} ({r['score']:.2f})")
    for t in list(by_talk)[:8]:
        print(f'   {titles[t][:50]:50s} -> {", ".join(by_talk[t])}')

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False)

    if not apply:
        print('\nDry run only. Re-run with --apply to write talk_topics.')
        return

    # 5. Replace talk_topics
    client = create_client(public_config['SUPABASE_URL'], secrets['SUPABASE_SERVICE_KEY'])
    client.table('talk_topics').delete().neq('topic', '').execute()
    for i in range(0, len(rows), BATCH_SIZE * 4):
        client.table('talk_topics').insert(rows[i:i + BATCH_SIZE * 4]).execute()
    total = client.table('talk_topics').select('talk_id', count='exact').limit(1).execute().count
    print(f'\n✅ talk_topics now has {total} rows.')


if __name__ == '__main__':
    main()
