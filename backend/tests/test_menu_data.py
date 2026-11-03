"""Menu allergen data checks (layer 1). Run before every deploy (deploy.ps1).

Hard failures: anything that would make Pig name the wrong allergens. Warnings: gaps
the restaurant owner has to fill (UNKNOWN items, vegan tags that contradict the list);
those are spoken honestly as "I don't have allergen info", so they do not block deploys.
"""

import json
import warnings
from pathlib import Path

import pytest

from agent import allergen_facts as af

BACKEND = Path(__file__).resolve().parent.parent
KB_PATH = BACKEND.parent / "assets" / "menu_knowledge_base_json.txt"
APP_EMBEDDINGS = BACKEND.parent / "assets" / "menu_embeddings.json"
AGENT_EMBEDDINGS = BACKEND / "assets" / "menu_embeddings.json"

_ANIMAL = {"milk", "egg", "fish", "shellfish", "pork", "chicken fat"}


def _kb_items() -> list[dict]:
    kb = json.loads(KB_PATH.read_text(encoding="utf-8"))
    return [item for cat in kb["menu_categories"] for item in cat["items"]]


def _chunks() -> dict[str, dict]:
    data = json.loads(AGENT_EMBEDDINGS.read_text(encoding="utf-8"))
    return {c["id"]: c for c in data["chunks"] if c["metadata"]["type"] == "menu_item"}


def test_embedding_copies_are_identical():
    # CLAUDE.md invariant: the backend file is a copy of the Flutter asset.
    assert APP_EMBEDDINGS.read_bytes() == AGENT_EMBEDDINGS.read_bytes()


def test_menu_item_ids_are_unique():
    kb_ids = [item["id"] for item in _kb_items()]
    assert len(kb_ids) == len(set(kb_ids)), f"duplicate ids in KB: {kb_ids}"
    data = json.loads(AGENT_EMBEDDINGS.read_text(encoding="utf-8"))
    chunk_ids = [c["id"] for c in data["chunks"]]
    assert len(chunk_ids) == len(set(chunk_ids)), "duplicate chunk ids in embeddings"


def test_every_allergen_value_is_mapped():
    for item in _kb_items():
        af.canonical(item.get("allergens", []))   # raises on an unmapped value


def test_embeddings_match_knowledge_base():
    # The agent speaks from the embeddings text; it must say what the KB says.
    chunks = _chunks()
    for item in _kb_items():
        chunk = chunks.get(item["id"])
        assert chunk is not None, f"{item['id']} missing from embeddings; regenerate them"
        assert af.parse_allergen_line(chunk["text"]) == item.get("allergens"), (
            f"{item['id']} allergens differ between KB and embeddings; regenerate them"
        )


def test_facts_load_for_every_menu_item():
    af.load_facts.cache_clear()
    facts = af.load_facts()
    assert set(facts) == {item["id"] for item in _kb_items()}


def test_report_owner_data_gaps():
    """Never fails: surfaces what the owner must fill in."""
    for item in _kb_items():
        if "allergens" not in item:
            warnings.warn(f"UNKNOWN allergens: {item['id']} {item['name']}", stacklevel=1)
            continue
        tags = " ".join(
            str(item.get(k, "")) for k in ("best_for", "dietary_options", "vegan")
        ).lower()
        listed = af.canonical(item["allergens"]) & _ANIMAL
        if ("vegan" in tags or item.get("vegan") is True) and listed:
            warnings.warn(
                f"vegan tag contradicts allergens: {item['id']} {item['name']} lists {sorted(listed)}",
                stacklevel=1,
            )


@pytest.mark.parametrize("value", ["diary", "nut", "gluten"])
def test_unmapped_value_is_rejected(value):
    with pytest.raises(ValueError):
        af.canonical([value])
