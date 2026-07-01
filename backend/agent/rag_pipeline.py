"""RAG retrieval — Python port of the similarity logic in lib/services/rag_service.dart.

Pipeline per user turn:
1. Enrich the query with the last 2 prior user turns (same as the Dart version).
2. Embed the enriched query via the existing Firebase `generateEmbedding` function
   (text-embedding-004, task_type RETRIEVAL_QUERY — no auth).
3. Cosine similarity against all 52 menu chunks (numpy, off the event loop).
4. Threshold 0.25: below -> BELOW_THRESHOLD; at/above -> top-6 chunks joined as context.
"""

import asyncio
import json
import os
from functools import lru_cache
from pathlib import Path

import httpx
import numpy as np

EMBEDDING_URL = os.getenv(
    "EMBEDDING_FUNCTION_URL",
    "https://us-central1-ooinkai.cloudfunctions.net/generateEmbedding",
)
RAG_THRESHOLD = 0.25          # matches AppConfig.minSimilarityThreshold
TOP_K = 6                     # matches AppConfig.topKChunks
BELOW_THRESHOLD = "BELOW_THRESHOLD"

_ASSETS_PATH = Path(__file__).resolve().parent.parent / "assets" / "menu_embeddings.json"


@lru_cache(maxsize=1)
def _load_chunks() -> tuple[list[str], np.ndarray]:
    """Load menu_embeddings.json once. Returns (texts, L2-normalized embedding matrix)."""
    with open(_ASSETS_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    chunks = data["chunks"]  # file is {"model","dimension","chunks":[{id,text,embedding,...}]}
    texts = [c["text"] for c in chunks]
    matrix = np.asarray([c["embedding"] for c in chunks], dtype=np.float32)
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return texts, matrix / norms


async def generate_embedding(text: str) -> list[float]:
    """Call the Firebase callable function. Response shape: {"result": {"embedding": [...]}}."""
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.post(
            EMBEDDING_URL,
            json={"data": {"text": text}},
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()
        return resp.json()["result"]["embedding"]


def _rank(query_embedding: list[float]) -> tuple[list[int], float]:
    """Top-K chunk indices + best cosine score. Runs in an executor (CPU-bound)."""
    _, normalized = _load_chunks()
    q = np.asarray(query_embedding, dtype=np.float32)
    qn = np.linalg.norm(q)
    if qn == 0:
        return [], 0.0
    scores = normalized @ (q / qn)  # cosine: both sides unit-normalized
    top_idx = np.argsort(scores)[::-1][:TOP_K]
    return top_idx.tolist(), float(scores[top_idx[0]])


async def find_relevant_context(user_message: str, history: list[str]) -> tuple[str, float]:
    """Mirror rag_service.dart: returns (context_text, top_score) or (BELOW_THRESHOLD, top_score).

    `history` is the list of PRIOR user utterances (current message passed separately).
    """
    recent = history[-2:] if len(history) >= 2 else history
    enriched = "\n".join([*recent, user_message]) if recent else user_message

    query_embedding = await generate_embedding(enriched)
    loop = asyncio.get_running_loop()
    top_idx, top_score = await loop.run_in_executor(None, _rank, query_embedding)

    if not top_idx or top_score < RAG_THRESHOLD:
        return BELOW_THRESHOLD, top_score

    texts, _ = _load_chunks()
    context = "\n\n".join(texts[i] for i in top_idx)
    return context, top_score
