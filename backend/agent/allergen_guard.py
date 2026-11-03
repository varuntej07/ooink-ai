"""Allergen guard: deterministic allergen answers and a pre-speech check.

Three kinds of reply, decided per turn from the customer's words only (no model call):
- Allergen question ("does the Kotteri have sesame?", "I'm allergic to peanuts"):
  compose_reply() answers from the menu data. The LLM and RAG are never called.
- Menu reply after an allergy was mentioned this session: the LLM answers, guard_stream()
  blocks unsafe sentences and appends a heads-up for named dishes that carry the
  allergy or have no allergen data.
- Anything else: the LLM answers and guard_stream() still blocks unsafe sentences.

Everything here is a pure function of the chat history, because preemptive generation
runs llm_node several times per turn and discards some runs.

Never say "safe" or "free of": the guard can only repeat what the menu lists, and the
kitchen's own policy is that it can't guarantee zero cross-contamination.
"""

import logging
import re
from collections.abc import AsyncIterable, AsyncIterator
from dataclasses import dataclass

from livekit.agents import FlushSentinel, llm

from . import allergen_facts as af
from .allergen_facts import DishFacts
from .speech_text import _SENTENCE_BOUNDARIES

logger = logging.getLogger(__name__)

CROSS_CONTAMINATION = "The kitchen can't guarantee zero cross-contamination."
_GENERIC_FACT = "I can only tell you what each dish lists, and " + CROSS_CONTAMINATION[0].lower() + CROSS_CONTAMINATION[1:]
_OPENERS = ("Oink! ", "Good thinking. ", "Okay! ")

# Allergen words a customer might say -> canonical allergens. Order matters: specific
# nut kinds before the generic "nut". Matched on text with dish names stripped out.
_LEXICON: list[tuple[str, frozenset[str]]] = [
    (r"dairy|milk|lactose|butter|cheese|cream", frozenset({"milk"})),
    (r"eggs?", frozenset({"egg"})),
    (r"shellfish|shrimps?|prawns?|crabs?|lobsters?|crustaceans?|scallops?|clams?|oysters?|mussels?",
     frozenset({"shellfish"})),
    (r"fish|anchovy|anchovies", frozenset({"fish"})),
    (r"tree nuts?|almonds?|cashews?|walnuts?|pecans?|pistachios?|hazelnuts?|macadamias?",
     frozenset({"tree nuts"})),
    (r"peanuts?|pea nuts?|pee nuts?|groundnuts?", frozenset({"peanuts"})),
    (r"nuts?|nutty", frozenset({"peanuts", "tree nuts"})),
    (r"wheat|gluten|celiac|coeliac", frozenset({"wheat"})),
    (r"soy|soya|soybeans?", frozenset({"soy"})),
    (r"sesame|tahini", frozenset({"sesame"})),
]
_ALLERGEN_RE = re.compile(r"\b(?:" + "|".join(f"({p})" for p, _ in _LEXICON) + r")\b")
_ALLERGY_WORD_RE = re.compile(r"\ballerg\w*")

# An allergy is stated or implied: these alone make the turn an allergen question.
_STRONG_CUE = re.compile(
    r"\b(allerg\w*|intoleran\w*|celiac|coeliac|anaphyla\w*|epi ?pens?|cross ?contam\w*)"
)
# The customer has to avoid something: marks the allergen for the rest of the session.
_RESTRICTION_CUE = re.compile(
    r"\b(allerg\w*|intoleran\w*|sensitiv\w*|react\w*|avoid\w*|free|safe|"
    r"(can't|cant|cannot|can not|don't|dont|do not|shouldn't|shouldnt|won't|wont)\s+"
    r"(eat|have|do|handle|tolerate|take)|celiac|coeliac)\b"
)
# The customer is asking whether a dish contains something.
_INQUIRY_CUE = re.compile(
    r"\b(has|have|having|got|any|is there|are there|contain\w*|with|without|in it|in that|"
    r"in this|in there|made with|come with|comes with|use|uses|used)\b"
)
# "Is the Kotteri okay for him?" / "Is the Shoyu okay then?" after an allergy was mentioned.
# Bare "okay" only counts after is/are/be, so "Okay, what should I order?" stays an LLM turn.
_SAFETY_CUE = re.compile(
    r"\b(safe|okay for|ok for|fine for|alright for|all right for|good for|work for)\b"
    r"|\b(is|are|be|would|will)\b[^.?!]*\b(okay|ok|alright|all right|fine)\b"
    r"|\bcan (he|she|i|we|they|my \w+) (have|eat|get)\b"
)
_PRONOUN = re.compile(r"\b(it|that|this|those|these|them|they|one|ones)\b")

# Pre-speech check vocabulary.
_TOKEN = re.compile(r"[a-z0-9']+")
_NEGATIONS = frozenset({
    "no", "not", "never", "without", "zero", "free", "none", "nothing", "nor", "neither",
    "isn't", "isnt", "aren't", "arent", "doesn't", "doesnt", "don't", "dont", "won't", "wont",
    "wasn't", "wasnt", "hasn't", "hasnt", "haven't", "havent", "lacks", "lack",
    "skip", "skips", "hold", "remove", "removed", "omit", "leave", "minus",
})
_STRONG_REASSURANCE = re.compile(
    r"\b(safe|safely|safer|good to go|you'?ll be (fine|okay|ok|good|alright)|allergy friendly|"
    r"nut friendly|won'?t (react|be a problem)|nothing to worry)\b"
)
_WEAK_REASSURANCE = re.compile(r"\b(no worries|no problem|you'?re (good|fine|okay|ok|set))\b")
_DIETARY_CLAIM = re.compile(
    r"\b(it|that|this|they|both|dish|one|each|all|everything)\s*(is|are|'s|s|'re|re)\s+"
    r"(\S+\s+)?(vegan|vegetarian|halal|kosher|plant based)\b"
)


@dataclass(frozen=True)
class AllergenSignal:
    now: frozenset[str] = frozenset()       # allergens named in the current utterance
    session: frozenset[str] = frozenset()   # allergens the customer must avoid, any turn
    question: bool = False                  # answer with compose_reply(), not the LLM

    @property
    def asked(self) -> frozenset[str]:
        return self.now | self.session


EMPTY_SIGNAL = AllergenSignal()


def allergens_in(text: str) -> frozenset[str]:
    """Canonical allergens named in the text (dish names ignored)."""
    found: set[str] = set()
    for match in _ALLERGEN_RE.finditer(af.strip_dish_names(text)):
        group = next(i for i, g in enumerate(match.groups()) if g is not None)
        found |= _LEXICON[group][1]
    return frozenset(found)


def _restricted(text: str) -> frozenset[str]:
    """Allergens this utterance says the customer has to avoid."""
    stripped = af.strip_dish_names(text)
    return allergens_in(text) if _RESTRICTION_CUE.search(stripped) else frozenset()


def detect(current: str, prior_user_texts: list[str]) -> AllergenSignal:
    stripped = af.strip_dish_names(current)
    now = allergens_in(current)
    session = frozenset().union(*(_restricted(t) for t in [*prior_user_texts, current]))
    question = bool(
        (now and (_RESTRICTION_CUE.search(stripped) or _INQUIRY_CUE.search(stripped)))
        or _STRONG_CUE.search(stripped)
        or (session and _SAFETY_CUE.search(stripped))
    )
    return AllergenSignal(now=now, session=session, question=question)


def dishes_for(current: str, prior_user_texts: list[str], last_assistant: str) -> list[DishFacts]:
    """Dishes the question is about. "Does it have nuts?" looks back at the last two
    customer turns, then at Pig's last reply."""
    dishes = af.resolve(current)
    if dishes or not _PRONOUN.search(af.normalize(current)):
        return dishes
    for text in [*reversed(prior_user_texts[-2:]), last_assistant]:
        if dishes := af.resolve(text):
            return dishes
    return []


def _is_plural(word: str) -> bool:
    return word.endswith("s") and word not in ("shellfish",)


def _speakable(allergens) -> list[str]:
    """Allergens to talk about, with "peanuts" + "tree nuts" (a generic "nuts" question)
    said once as "nuts"."""
    items = set(allergens)
    if {"peanuts", "tree nuts"} <= items:
        items = (items - {"peanuts", "tree nuts"}) | {"nuts"}
    return af.ordered(items)


def _present_words(dish: DishFacts, asked: list[str]) -> list[str]:
    """How to name each asked allergen the dish lists, using the dish's own wording."""
    listed = dish.allergens or frozenset()
    words: list[str] = []
    for allergen in asked:
        if not dish.has(allergen):
            continue
        if allergen == "nuts":
            kinds = [k for k in ("peanuts", "tree nuts", "nuts") if k in listed]
        else:
            kinds = [allergen if allergen in listed else "nuts"]
        for kind in kinds:
            if af.SPOKEN[kind] not in words:
                words.append(af.SPOKEN[kind])
    return words


def _dish_sentence(dish: DishFacts, asked: list[str]) -> str:
    if dish.allergens is None:
        return f"I don't have allergen info for the {dish.name}."
    if not dish.allergens:
        return f"The {dish.name} has no allergens on its menu list."
    listed = af.spoken_list([af.SPOKEN[a] for a in af.ordered(dish.allergens)])
    sentence = f"The {dish.name} lists {listed}."
    present = _present_words(dish, asked)
    absent = [af.SPOKEN[a] for a in asked if not dish.has(a)]
    if present:
        sentence += f" So yes, it has {af.spoken_list(present)}."
    if absent:
        verb = "aren't" if len(absent) > 1 or _is_plural(absent[0]) else "isn't"
        phrase = af.spoken_list(absent)
        sentence += f" {phrase[0].upper()}{phrase[1:]} {verb} on its list."
    return sentence


def _allergen_overview(allergen: str) -> str:
    facts = af.load_facts().values()
    present = [d for d in facts if d.has(allergen)]
    word = af.SPOKEN[allergen]
    label = word[0].upper() + word[1:]
    if not present:
        return f"No dish on the menu lists {word}."
    ramen = [d for d in facts if d.category == af.RAMEN_CATEGORY]
    if ramen and all(d.has(allergen) for d in ramen):
        others = [f"the {d.name}" for d in present if d.category != af.RAMEN_CATEGORY]
        parts = ["every ramen", *others]
    else:
        parts = [f"the {d.name}" for d in present]
    verb = "show" if _is_plural(word) else "shows"
    if len(parts) > 4:
        return f"{label} {verb} up in {len(present)} items, including {af.spoken_list(parts[:3])}."
    return f"{label} {verb} up in {af.spoken_list(parts)}."


def compose_reply(signal: AllergenSignal, dishes: list[DishFacts], variant: int) -> str:
    """The full spoken answer to an allergen question, built only from the menu data."""
    asked = _speakable(signal.asked)
    opener = _OPENERS[variant % len(_OPENERS)]
    if not asked and not dishes:
        return (
            f"{opener}Tell me which allergy to check and I'll say what each dish lists. "
            f"{CROSS_CONTAMINATION}"
        )
    if dishes:
        body = [_dish_sentence(d, asked) for d in dishes]
    else:
        body = [_allergen_overview(a) for a in asked]
        unknown = [f"the {d.name}" for d in af.load_facts().values() if d.allergens is None]
        if unknown:
            body.append(f"I don't have allergen info for {af.spoken_list(unknown)}.")
    return opener + " ".join(body) + " " + CROSS_CONTAMINATION


async def speak_reply(reply: str, signal: AllergenSignal, dishes: list[DishFacts]) -> AsyncIterator[str]:
    """llm_node output for a template turn: the reply, then one log line."""
    yield reply
    logger.info(
        "allergen_turn",
        extra={
            "path": "template",
            "allergens": sorted(signal.asked),
            "dishes": [d.id for d in dishes],
            "unknown_dishes": [d.id for d in dishes if d.allergens is None],
        },
    )


def check_sentence(sentence: str, signal: AllergenSignal) -> bool:
    """True if the sentence must not be spoken: it denies an allergen, reassures about
    one, or claims a dietary label."""
    stripped = af.strip_dish_names(sentence)
    tokens = _TOKEN.findall(stripped)
    allergen_idx = {len(_TOKEN.findall(stripped[: m.start()])) for m in _ALLERGEN_RE.finditer(stripped)}
    allergen_idx |= {len(_TOKEN.findall(stripped[: m.start()])) for m in _ALLERGY_WORD_RE.finditer(stripped)}
    for i in allergen_idx:
        window = tokens[max(0, i - 4): i] + tokens[i + 1: i + 4]
        if any(t in _NEGATIONS for t in window):
            return True
    mentions = bool(allergen_idx)
    if _STRONG_REASSURANCE.search(stripped) and (mentions or signal.session):
        return True
    if _WEAK_REASSURANCE.search(stripped) and mentions:
        return True
    return bool(_DIETARY_CLAIM.search(stripped))


def _fact_line(sentence: str, signal: AllergenSignal) -> str:
    dishes = af.resolve(sentence)
    if not dishes:
        return _GENERIC_FACT
    asked = _speakable(signal.asked)
    return " ".join(_dish_sentence(d, asked) for d in dishes) + " " + CROSS_CONTAMINATION


def heads_up(text: str, signal: AllergenSignal) -> str | None:
    """A warning for dishes Pig named that list a session allergen or have no data."""
    if not signal.session:
        return None
    session = _speakable(signal.session)
    listed, unknown = [], []
    for dish in af.resolve(text, limit=6):
        if dish.allergens is None:
            unknown.append(f"the {dish.name}")
        elif present := _present_words(dish, session):
            listed.append(f"the {dish.name} lists {af.spoken_list(present)}")
    parts = listed + ([f"I don't have allergen info for {af.spoken_list(unknown)}"] if unknown else [])
    if not parts:
        return None
    return "Heads up: " + ", and ".join(parts) + "."


def _split_sentences(text: str) -> list[str]:
    """Split text that ends on a boundary into sentences, keeping each one's whitespace."""
    out = []
    while text:
        cut = min(
            (text.find(b) + len(b) for b in _SENTENCE_BOUNDARIES if b in text), default=len(text)
        )
        out.append(text[:cut])
        text = text[cut:]
    return out


async def guard_stream(
    stream: AsyncIterable[llm.ChatChunk | str | FlushSentinel], signal: AllergenSignal
) -> AsyncIterator[llm.ChatChunk | str | FlushSentinel]:
    """Pass the LLM reply through sentence by sentence, replacing the first unsafe sentence
    with a fact line and dropping later ones. TTS already waits for whole sentences
    (speech_text.sanitize_stream), so this adds no delay before audio.

    Text chunks are re-emitted as plain strings. Chunks without text (usage) pass through
    unchanged. The Pig has no tools, so a chunk carrying both text and a tool call would
    lose the call here; revisit if tools are added.
    """
    buffer = ""
    spoken: list[str] = []
    blocked = 0

    def check(sentence: str) -> str | None:
        nonlocal blocked
        if not sentence.strip() or not check_sentence(sentence, signal):
            spoken.append(sentence)
            return sentence
        blocked += 1
        if blocked > 1:
            return None
        trailing = sentence[len(sentence.rstrip()):] or " "
        return _fact_line(sentence, signal) + trailing

    async for chunk in stream:
        if isinstance(chunk, FlushSentinel):
            if buffer:
                if (out := check(buffer)) is not None:
                    yield out
                buffer = ""
            yield chunk
            continue
        text = chunk if isinstance(chunk, str) else (chunk.delta.content if chunk.delta else None)
        if not text:
            yield chunk
            continue
        buffer += text
        cut = max((buffer.rfind(b) + len(b) for b in _SENTENCE_BOUNDARIES if b in buffer), default=0)
        if cut:
            for sentence in _split_sentences(buffer[:cut]):
                if (out := check(sentence)) is not None:
                    yield out
            buffer = buffer[cut:]
    if buffer and (out := check(buffer)) is not None:
        yield out

    warning = heads_up("".join(spoken), signal)
    if warning:
        yield (" " if spoken and not spoken[-1].endswith((" ", "\n")) else "") + warning
    if blocked or signal.session:
        logger.info(
            "allergen_turn",
            extra={
                "path": "llm",
                "allergens": sorted(signal.session),
                "blocked": blocked,
                "heads_up": warning is not None,
            },
        )
