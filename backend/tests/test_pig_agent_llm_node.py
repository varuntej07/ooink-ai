"""PigAgent.llm_node wiring: template turns skip RAG and the LLM, LLM turns are guarded.

The LLM and the RAG lookup are faked, so this runs offline.
"""

import pytest
from livekit.agents import Agent, ModelSettings, llm

from agent import pig_agent
from agent.pig_agent import PigAgent
from agent.rag_pipeline import BELOW_THRESHOLD


class Calls:
    def __init__(self) -> None:
        self.llm = 0
        self.rag = 0
        self.ctx: llm.ChatContext | None = None
        self.reply = {"text": "That one's totally nut-free!"}


@pytest.fixture
def fake(monkeypatch):
    calls = Calls()

    async def fake_llm_node(_agent, chat_ctx, _tools, _model_settings):
        calls.llm += 1
        calls.ctx = chat_ctx
        yield llm.ChatChunk(id="c", delta=llm.ChoiceDelta(content=calls.reply["text"]))

    async def fake_rag(user_text, history):
        calls.rag += 1
        return BELOW_THRESHOLD, 0.0

    monkeypatch.setattr(Agent.default, "llm_node", fake_llm_node)
    monkeypatch.setattr(pig_agent, "find_relevant_context", fake_rag)
    monkeypatch.delenv("ALLERGEN_GUARD", raising=False)
    return calls


def _ctx(*turns: tuple[llm.ChatRole, str]) -> llm.ChatContext:
    ctx = llm.ChatContext()
    for role, text in turns:
        ctx.add_message(role=role, content=text)
    return ctx


def _system_texts(ctx: llm.ChatContext) -> list[str]:
    return [i.text_content or "" for i in ctx.items if isinstance(i, llm.ChatMessage) and i.role == "system"]


async def _run(ctx: llm.ChatContext) -> str:
    node = await PigAgent().llm_node(ctx, [], ModelSettings())
    out = []
    async for chunk in node:
        if isinstance(chunk, str):
            out.append(chunk)
        elif isinstance(chunk, llm.ChatChunk) and chunk.delta and chunk.delta.content:
            out.append(chunk.delta.content)
    return "".join(out)


async def test_allergen_question_uses_template_only(fake):
    text = await _run(_ctx(("user", "Does the Vegetarian Miso have dairy?")))
    assert fake.llm == 0 and fake.rag == 0
    assert "The Vegetarian Miso Ramen lists dairy, wheat, and soy." in text


async def test_unsafe_llm_sentence_is_replaced(fake):
    text = await _run(_ctx(("user", "What should I get?")))
    assert fake.llm == 1
    assert "nut-free" not in text
    assert text.startswith("I can only tell you what each dish lists")


async def test_allergy_session_adds_note_and_heads_up(fake):
    fake.reply["text"] = "Add the Garlic Peanut Chili Oil for heat!"
    ctx = _ctx(
        ("user", "My son's allergic to peanuts."),
        ("assistant", "Oink! Thanks for telling me."),
        ("user", "What can I add to make it spicier?"),
    )
    text = await _run(ctx)
    assert fake.llm == 1
    assert text.endswith("Heads up: I don't have allergen info for the Garlic Peanut Chili Oil.")
    assert fake.ctx is not None
    assert any("allergy to: peanuts" in n for n in _system_texts(fake.ctx))
    # The session's own context is never mutated (preemptive replies depend on it).
    assert not any("allergy to" in n for n in _system_texts(ctx))


async def test_kill_switch_restores_old_behavior(fake, monkeypatch):
    monkeypatch.setenv("ALLERGEN_GUARD", "off")
    text = await _run(_ctx(("user", "Does the Vegetarian Miso have dairy?")))
    assert fake.llm == 1 and fake.rag == 1
    assert text == "That one's totally nut-free!"
