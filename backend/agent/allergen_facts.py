"""Per-dish allergen facts: the data the allergen guard speaks from.

Parsed from the `Allergens: [...]` line already in each menu-item chunk of
menu_embeddings.json (written by scripts/generate_embeddings.py), so there is no second
data file to keep in sync. A dish whose chunk has no Allergens line is UNKNOWN (None),
never "no allergens".

An allergen value that is not in ALLERGEN_VALUES raises at load: the worker refuses to
start rather than run with an allergen it cannot name.
"""

import ast
import json
import re
from dataclasses import dataclass
from functools import lru_cache

from .rag_pipeline import _ASSETS_PATH

# Raw value in the menu data -> canonical allergen. The FDA's nine major allergens
# (milk, egg, fish, shellfish, tree nuts, peanuts, wheat, soy, sesame), plus "nuts" when
# the menu does not say which kind, plus the non-FDA extras the menu lists.
ALLERGEN_VALUES = {
    "dairy": "milk",
    "milk": "milk",
    "eggs": "egg",
    "egg": "egg",
    "fish": "fish",
    "anchovies": "fish",
    "shellfish": "shellfish",
    "tree nuts": "tree nuts",
    "peanuts": "peanuts",
    "contains nuts": "nuts",
    "possible nuts in some ingredients": "nuts",
    "wheat": "wheat",
    "soy": "soy",
    "sesame": "sesame",
    "pork": "pork",
    "garlic": "garlic",
    "chicken fat": "chicken fat",
}

# How each canonical allergen is said out loud.
SPOKEN = {
    "milk": "dairy",
    "egg": "eggs",
    "fish": "fish",
    "shellfish": "shellfish",
    "tree nuts": "tree nuts",
    "peanuts": "peanuts",
    "nuts": "nuts",
    "wheat": "wheat",
    "soy": "soy",
    "sesame": "sesame",
    "pork": "pork",
    "garlic": "garlic",
    "chicken fat": "chicken fat",
}

# Order allergens are listed in when spoken: FDA nine first, extras last.
_ORDER = list(SPOKEN)

NUT_KINDS = frozenset({"peanuts", "tree nuts", "nuts"})

RAMEN_CATEGORY = "Signature Ramen Bowls"


@dataclass(frozen=True)
class DishFacts:
    id: str
    name: str                           # spoken name, parenthetical dropped
    category: str
    allergens: frozenset[str] | None    # None = the menu has no allergen info (UNKNOWN)

    def has(self, allergen: str) -> bool:
        """True if the dish lists the allergen. Unspecified "nuts" counts for both nut
        kinds, and asking about "nuts" matches any nut."""
        if self.allergens is None:
            return False
        if allergen == "nuts":
            return bool(self.allergens & NUT_KINDS)
        if allergen in self.allergens:
            return True
        return allergen in ("peanuts", "tree nuts") and "nuts" in self.allergens


def ordered(allergens) -> list[str]:
    return sorted(allergens, key=_ORDER.index)


def spoken_list(words: list[str]) -> str:
    """'a', 'a and b', 'a, b, and c'."""
    if len(words) <= 1:
        return "".join(words)
    if len(words) == 2:
        return f"{words[0]} and {words[1]}"
    return ", ".join(words[:-1]) + f", and {words[-1]}"


def parse_allergen_line(text: str) -> list[str] | None:
    """The raw values from a chunk's `Allergens: [...]` line, or None if it has none."""
    for line in text.splitlines():
        if line.startswith("Allergens:"):
            return list(ast.literal_eval(line.removeprefix("Allergens:").strip()))
    return None


def canonical(values: list[str]) -> frozenset[str]:
    unknown = [v for v in values if v.strip().lower() not in ALLERGEN_VALUES]
    if unknown:
        raise ValueError(f"unmapped allergen values in menu data: {unknown}")
    return frozenset(ALLERGEN_VALUES[v.strip().lower()] for v in values)


def _spoken_name(name: str) -> str:
    return re.sub(r"\s*\([^)]*\)", "", name).strip()


@lru_cache(maxsize=1)
def load_facts() -> dict[str, DishFacts]:
    """Every menu item in menu_embeddings.json, keyed by chunk id. Cached per process."""
    with open(_ASSETS_PATH, "r", encoding="utf-8") as f:
        chunks = json.load(f)["chunks"]
    facts: dict[str, DishFacts] = {}
    for chunk in chunks:
        meta = chunk["metadata"]
        if meta.get("type") != "menu_item":
            continue
        if chunk["id"] in facts:
            raise ValueError(f"duplicate menu item id in {_ASSETS_PATH.name}: {chunk['id']}")
        raw = parse_allergen_line(chunk["text"])
        facts[chunk["id"]] = DishFacts(
            id=chunk["id"],
            name=_spoken_name(meta["name"]),
            category=meta["category"],
            allergens=None if raw is None else canonical(raw),
        )
    return facts


# Phrase a customer (or Pig) might say -> the dish ids it can mean. Ambiguous names map
# to every candidate, because covering both dishes is safer than guessing one.
PHRASES: dict[str, tuple[str, ...]] = {
    "mala kotteri": ("ramen_001",),
    "mala ramen": ("ramen_002",),
    "mala": ("ramen_001", "ramen_002"),
    "kotteri": ("ramen_001", "ramen_003"),
    # Misheard names, from the menu's "also_known_as" fields.
    "cot terry": ("ramen_001", "ramen_003"),
    "koh terry": ("ramen_001", "ramen_003"),
    "cottage ramen": ("ramen_003",),
    "shoyu": ("ramen_004",),
    "soy sauce ramen": ("ramen_004",),
    "soy ramen": ("ramen_004",),
    "show you ramen": ("ramen_004",),
    "show yu ramen": ("ramen_004",),
    "shio": ("ramen_005",),
    "she oh ramen": ("ramen_005",),
    "salt ramen": ("ramen_005",),
    "shiro ramen": ("ramen_005",),
    "mapo tofu": ("ramen_006",),
    "mapo": ("ramen_006",),
    "spicy vegetarian miso": ("ramen_007",),
    "spicy veggie miso": ("ramen_007",),
    "spicy veg miso": ("ramen_007",),
    "spicy miso": ("ramen_007",),
    "vegetarian miso": ("ramen_008",),
    "veggie miso": ("ramen_008", "ramen_007"),
    "veg miso": ("ramen_008", "ramen_007"),
    "miso": ("ramen_008", "ramen_007"),
    "shanghai": ("ramen_009",),
    "malaysian fried chicken": ("appetizer_001",),
    "ayam goreng": ("appetizer_001",),
    "fried chicken": ("appetizer_001",),
    "chicken sandwich": ("appetizer_002",),
    "sandwich": ("appetizer_002",),
    "gyoza": ("appetizer_003",),
    "goza": ("appetizer_003",),
    "go za": ("appetizer_003",),
    "joza": ("appetizer_003",),
    "dumpling": ("appetizer_003",),
    "potsticker": ("appetizer_003",),
    "pot sticker": ("appetizer_003",),
    "cucumber salad": ("appetizer_004",),
    "cucumber": ("appetizer_004",),
    "extra toppings": ("side_001",),
    "topping": ("side_001",),
    "extra noodles": ("side_002",),
    "mala chili oil": ("side_003",),
    "mala chilli oil": ("side_003",),
    "mala oil": ("side_003",),
    "garlic peanut chili oil": ("side_004",),
    "garlic peanut chilli oil": ("side_004",),
    "peanut chili oil": ("side_004",),
    "peanut chilli oil": ("side_004",),
    "garlic peanut oil": ("side_004",),
    "chili oil": ("side_003", "side_004"),
    "chilli oil": ("side_003", "side_004"),
    "chile oil": ("side_003", "side_004"),
}

# Longest phrase first, so "mala chili oil" wins over "mala" and "chili oil".
_PHRASE_RE = re.compile(
    r"\b(" + "|".join(re.escape(p) for p in sorted(PHRASES, key=len, reverse=True)) + r")s?\b"
)


def normalize(text: str) -> str:
    text = text.lower().replace("’", "'").replace("-", " ")
    return re.sub(r"\s+", " ", text)


def resolve(text: str, limit: int = 3) -> list[DishFacts]:
    """Dishes named in the text, in order of first mention, at most `limit`."""
    facts = load_facts()
    ids: list[str] = []
    for match in _PHRASE_RE.finditer(normalize(text)):
        for dish_id in PHRASES[match.group(1)]:
            if dish_id not in ids and dish_id in facts:
                ids.append(dish_id)
    return [facts[i] for i in ids[:limit]]


def strip_dish_names(text: str) -> str:
    """Normalized text with dish names replaced by a placeholder, so "Mapo Tofu" or
    "Garlic Peanut Chili Oil" are not read as allergen mentions."""
    return _PHRASE_RE.sub(" dish ", normalize(text))
