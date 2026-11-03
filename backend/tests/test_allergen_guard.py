"""Allergen guard (layers 2-4): detection, dish lookup, templates, pre-speech check.

No network, no LLM. Every case here is deterministic, so a failure is a real regression.
"""

import pytest
from livekit.agents import FlushSentinel, llm

from agent import allergen_facts as af
from agent import allergen_guard as g

PEANUT_SESSION = g.AllergenSignal(session=frozenset({"peanuts"}))


# ---- facts -------------------------------------------------------------------------

def test_facts_parse_from_embeddings():
    facts = af.load_facts()
    assert len(facts) == 17
    assert facts["ramen_008"].allergens == {"milk", "soy", "wheat"}
    assert facts["ramen_007"].allergens == {"soy", "wheat", "nuts", "milk"}
    assert facts["ramen_004"].has("fish")                    # anchovies
    assert facts["ramen_009"].name == "Shanghai Style Ramen"  # parenthetical dropped
    assert {i for i, d in facts.items() if d.allergens is None} == {
        "side_001", "side_002", "side_003", "side_004",
    }


def test_generic_nuts_match_both_kinds():
    spicy = af.load_facts()["ramen_007"]
    assert spicy.has("peanuts") and spicy.has("tree nuts") and spicy.has("nuts")
    salad = af.load_facts()["appetizer_004"]
    assert salad.has("peanuts") and salad.has("nuts") and not salad.has("tree nuts")


def test_unknown_dish_never_has_anything():
    oil = af.load_facts()["side_003"]
    assert not any(oil.has(a) for a in af.SPOKEN)


@pytest.mark.parametrize(
    ("text", "ids"),
    [
        ("does the vegetarian miso have dairy", ["ramen_008"]),
        ("spicy vegetarian miso please", ["ramen_007"]),
        ("veggie miso", ["ramen_008", "ramen_007"]),
        ("the kotteri", ["ramen_001", "ramen_003"]),
        ("mala kotteri", ["ramen_001"]),
        ("mala chili oil", ["side_003"]),
        ("Garlic-Peanut Chili Oil", ["side_004"]),
        ("which chili oil", ["side_003", "side_004"]),
        ("two gyoza and the dumplings", ["appetizer_003"]),
        ("how about the fried chicken", ["appetizer_001"]),
        ("does the show you ramen have fish", ["ramen_004"]),
        ("is there sesame in the cot terry", ["ramen_001", "ramen_003"]),
        ("pot stickers please", ["appetizer_003"]),
        ("just ramen", []),
    ],
)
def test_resolve(text, ids):
    assert [d.id for d in af.resolve(text)] == ids


# ---- detection ---------------------------------------------------------------------

QUESTIONS = [
    "Does the Vegetarian Miso have dairy?",
    "What has peanuts?",
    "Is the Mala chili oil peanut-free?",
    "Veggie miso, any nuts?",
    "Anything gluten-free?",
    "Is it pee nut free?",
    "Is your kitchen nut-free?",
    "I'm allergic",
    "My son has a severe allergy",
    "I have celiac disease, what can I eat?",
    "Is there sesame in the Kotteri?",
    "Does the Shoyu contain fish?",
    "I'm lactose intolerant",
    "Any shellfish on the menu?",
    "Does it come with egg?",
    "is the cucumber salad made with peanuts",
    "I can't eat soy",
    "we avoid dairy",
    "what about cross contamination",
    "Does the gyoza have wheat?",
]

NOT_QUESTIONS = [
    "How much is the garlic peanut chili oil?",
    "Tell me about the Mapo Tofu Ramen",
    "Can I get extra egg?",
    "What's your most popular bowl?",
    "Is the Shanghai vegan?",
    "Hi Pig!",
    "What's in the Kotteri?",
    "Is it spicy?",
]


@pytest.mark.parametrize("text", QUESTIONS)
def test_allergen_questions_are_detected(text):
    assert g.detect(text, []).question


@pytest.mark.parametrize("text", NOT_QUESTIONS)
def test_ordinary_questions_go_to_the_llm(text):
    assert not g.detect(text, []).question


def test_allergy_is_remembered_for_the_session():
    signal = g.detect("What can I add to make it spicier?", ["My son's allergic to peanuts."])
    assert not signal.question
    assert signal.session == {"peanuts"}


@pytest.mark.parametrize(
    "followup",
    ["Is the kotteri okay for him?", "Is the Shoyu okay then?", "Can he have the Gyoza?", "Would the Shio be fine?"],
)
def test_safety_followup_uses_session_allergy(followup):
    signal = g.detect(followup, ["he can't eat sesame"])
    assert signal.question and signal.session == {"sesame"}


@pytest.mark.parametrize("followup", ["Okay, what should I order?", "Is the Shoyu good?", "Tell me a joke"])
def test_ordinary_followups_stay_with_the_llm(followup):
    assert not g.detect(followup, ["he can't eat sesame"]).question


def test_dish_names_are_not_allergen_mentions():
    assert g.allergens_in("the garlic peanut chili oil") == frozenset()
    assert g.allergens_in("mapo tofu ramen") == frozenset()
    assert g.allergens_in("the soy sauce ramen") == frozenset()
    assert g.detect("I'd love the garlic peanut chili oil", []).session == frozenset()


def test_ingredient_curiosity_does_not_mark_an_allergy():
    assert g.detect("Can I get extra egg?", []).session == frozenset()


def test_pronoun_looks_back_for_the_dish():
    dishes = g.dishes_for("does it have sesame?", ["tell me about the shoyu"], "")
    assert [d.id for d in dishes] == ["ramen_004"]
    dishes = g.dishes_for("does that one have nuts?", ["hi"], "The Cucumber Salad is great.")
    assert [d.id for d in dishes] == ["appetizer_004"]


def test_general_question_does_not_look_back():
    assert g.dishes_for("what has peanuts?", ["tell me about the shoyu"], "") == []


# ---- templates (the exact words Pig speaks) ------------------------------------------

def _reply(current, prior=(), last_assistant="", variant=0):
    prior = list(prior)
    signal = g.detect(current, prior)
    assert signal.question, current
    return g.compose_reply(signal, g.dishes_for(current, prior, last_assistant), variant)


def test_template_direct_dish():
    assert _reply("Does the Vegetarian Miso have dairy?") == (
        "Oink! The Vegetarian Miso Ramen lists dairy, wheat, and soy. So yes, it has dairy. "
        "The kitchen can't guarantee zero cross-contamination."
    )


def test_template_unknown_dish_never_answers_yes_or_no():
    reply = _reply("Is the Mala chili oil peanut-free?")
    assert reply == (
        "Oink! I don't have allergen info for the Mala Chili Oil. "
        "The kitchen can't guarantee zero cross-contamination."
    )


def test_template_ambiguous_dish_covers_both():
    reply = _reply("Veggie miso, any nuts?")
    assert "The Vegetarian Miso Ramen lists dairy, wheat, and soy. Nuts aren't on its list." in reply
    assert "The Spicy Vegetarian Miso Ramen lists dairy, nuts, wheat, and soy. So yes, it has nuts." in reply


def test_template_overview_lists_dishes_and_unknowns():
    reply = _reply("What has peanuts?")
    assert "Peanuts show up in the Spicy Vegetarian Miso Ramen and the Cucumber Salad." in reply
    assert "I don't have allergen info for the Extra Toppings, the Extra Noodles, the Mala Chili Oil, and the Garlic Peanut Chili Oil." in reply


def test_template_every_ramen():
    assert "Wheat shows up in every ramen, the Spicy Crispy Chicken Sandwich, and the Gyoza." in _reply(
        "Anything gluten-free?"
    )


def test_template_session_allergy_followup():
    reply = _reply("Is the kotteri okay for him?", ["he can't eat sesame"])
    assert "The Mala Kotteri Ramen lists eggs, wheat, soy, sesame, pork, and garlic. So yes, it has sesame." in reply


def test_template_allergy_without_allergen_asks_which():
    assert "Tell me which allergy to check" in _reply("I'm allergic")


@pytest.mark.parametrize("text", QUESTIONS)
def test_templates_never_reassure(text):
    reply = _reply(text)
    lowered = reply.lower()
    assert reply.endswith(g.CROSS_CONTAMINATION)
    for word in ("safe", " free", "fine for", "you're good", "staff"):
        assert word not in lowered, (word, reply)


def test_openers_rotate():
    assert {_reply("I'm allergic", variant=v).split(" ")[0] for v in range(3)} == {"Oink!", "Good", "Okay!"}


# ---- pre-speech check --------------------------------------------------------------

BLOCKED = [
    "That one's totally nut-free!",
    "There are no peanuts in the Shoyu.",
    "The Kotteri doesn't have any dairy.",
    "It's gluten free.",
    "Peanuts aren't in it.",
    "You can ask them to hold the peanuts.",
    "It's safe for your peanut allergy.",
    "No allergens in that one!",
    "It's free of sesame.",
    "Without any eggs, it's great.",
    "It's vegan.",
    "That's fully vegetarian.",
    "It's 100% halal.",
    "The Shio is dairy free.",
    "No worries about nuts there.",
    "Zero soy in the Gyoza.",
    "The Cucumber Salad is nut free if you skip the peanuts.",
    "It's free from shellfish.",
    "It doesnt contain wheat.",
    "Totally allergy-friendly!",
    "Don’t worry, there’s no sesame.",
    "This one has no dairy at all.",
    "They're kosher.",
    "Just remove the egg and you're set.",
]

BLOCKED_IN_SESSION = [
    "The Shoyu is safe for him.",
    "You'll be fine with the Shio.",
    "Good to go with the Mala Ramen!",
]

ALLOWED = [
    "The Kotteri has a rich pork broth.",
    "No problem! The Shoyu is a classic.",
    "Try the Mala Ramen, it's spicy.",
    "Extra noodles are free by the register.",
    "We have vegetarian options like the Vegetarian Miso Ramen.",
    "The Spicy Vegetarian Miso Ramen is my favorite.",
    "It comes with a soft egg.",
    "That's a safe bet for spice lovers.",
    "Oink, I'd go with the Kotteri.",
    "The Gyoza are pork dumplings.",
    "It's topped with sesame and garlic.",
    "Not too spicy, just right.",
    "The Shanghai Style Ramen (No Pork) is lighter.",
    "Free noodles at the register, no joke.",
]


@pytest.mark.parametrize("sentence", BLOCKED)
def test_unsafe_sentences_are_blocked(sentence):
    assert g.check_sentence(sentence, g.EMPTY_SIGNAL)


@pytest.mark.parametrize("sentence", BLOCKED_IN_SESSION)
def test_reassurance_blocked_after_allergy_mentioned(sentence):
    assert g.check_sentence(sentence, PEANUT_SESSION)
    assert not g.check_sentence(sentence, g.EMPTY_SIGNAL)


@pytest.mark.parametrize("sentence", ALLOWED)
def test_ordinary_sentences_pass(sentence):
    assert not g.check_sentence(sentence, g.EMPTY_SIGNAL)


def test_heads_up_names_allergy_and_unknowns():
    warning = g.heads_up("Try the Garlic Peanut Chili Oil or the Spicy Vegetarian Miso Ramen.", PEANUT_SESSION)
    assert warning == (
        "Heads up: the Spicy Vegetarian Miso Ramen lists nuts, and I don't have allergen "
        "info for the Garlic Peanut Chili Oil."
    )


def test_heads_up_silent_without_allergy_or_dish():
    assert g.heads_up("Try the Kotteri.", g.EMPTY_SIGNAL) is None
    assert g.heads_up("Here's a joke about pigs.", PEANUT_SESSION) is None
    assert g.heads_up("Try the Shoyu Ramen.", PEANUT_SESSION) is None


# ---- stream ------------------------------------------------------------------------

def _chunk(text: str | None, usage=None) -> llm.ChatChunk:
    return llm.ChatChunk(id="x", delta=llm.ChoiceDelta(content=text) if text is not None else None, usage=usage)


async def _collect(items, signal=g.EMPTY_SIGNAL):
    async def source():
        for item in items:
            yield item

    return [out async for out in g.guard_stream(source(), signal)]


def _text(outputs) -> str:
    return "".join(o for o in outputs if isinstance(o, str))


async def test_stream_passes_safe_text_unchanged():
    out = await _collect([_chunk("The Kot"), _chunk("teri is rich. Try"), _chunk(" it!")])
    assert _text(out) == "The Kotteri is rich. Try it!"


async def test_stream_replaces_unsafe_sentence_split_across_chunks():
    out = await _collect([_chunk("Great pick! The Shio is nut"), _chunk("-free. Enjoy!")])
    assert _text(out) == (
        "Great pick! The Shio Ramen lists eggs, fish, wheat, soy, and chicken fat. "
        "The kitchen can't guarantee zero cross-contamination. Enjoy!"
    )


async def test_stream_replaces_once_then_drops():
    out = await _collect([_chunk("It's nut free. It's dairy free. It's vegan. Yum!")])
    assert _text(out) == g._GENERIC_FACT + " Yum!"


async def test_stream_passes_usage_and_flush_through():
    usage_chunk = _chunk(None, usage=llm.CompletionUsage(completion_tokens=1, prompt_tokens=1, total_tokens=2))
    flush = FlushSentinel()
    out = await _collect([_chunk("Hello there"), flush, usage_chunk])
    assert out[0] == "Hello there"
    assert out[1] is flush
    assert out[2] is usage_chunk


async def test_stream_appends_heads_up_in_allergy_session():
    out = await _collect([_chunk("Add the Garlic Peanut Chili Oil for heat!")], PEANUT_SESSION)
    assert _text(out) == (
        "Add the Garlic Peanut Chili Oil for heat! Heads up: I don't have allergen info "
        "for the Garlic Peanut Chili Oil."
    )


async def test_stream_accepts_plain_strings():
    out = await _collect(["No peanuts in the Shoyu."])
    assert "lists eggs, fish, wheat, soy, and chicken fat" in _text(out)
