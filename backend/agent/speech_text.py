"""Clean the LLM's reply text before it reaches TTS (a subset of Aura's text_sanitizer).

The prompts already ask for plain spoken sentences; this is the safety net for what
slips through. It strips markdown and emoji, says prices the way a person would
("$19.50" -> "nineteen fifty"), and reads number ranges and symbols as words.

The stream is buffered to sentence boundaries so a token split like "$19" + ".50"
is cleaned as one price, not two.
"""

import re
from collections.abc import AsyncIterable, AsyncIterator

_SENTENCE_BOUNDARIES = (". ", "! ", "? ", ".\n", "!\n", "?\n", "\n")

_ONES = (
    "zero one two three four five six seven eight nine ten eleven twelve thirteen "
    "fourteen fifteen sixteen seventeen eighteen nineteen"
).split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()

_EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF☀-➿⬀-⯿️‍]+", flags=re.UNICODE
)
_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_BOLD_ITALIC = re.compile(r"(\*\*|__|\*|`)")
_LINE_MARKERS = re.compile(r"^\s*(#{1,6}\s+|[-*•]\s+|\d+[.)]\s+|>\s*)", flags=re.MULTILINE)
_NUM = r"\d+(?:\.\d{1,2})?"
_PRICE_RANGE = re.compile(rf"\$({_NUM})\s*(?:-|–|to)\s*\$?({_NUM})")
_PRICE = re.compile(rf"\$({_NUM})")
_NUMBER_RANGE = re.compile(r"\b(\d+)\s*[-–]\s*(\d+)\b")
_SLASH = re.compile(r"\s*/\s*")


def _int_words(n: int) -> str:
    if n < 20:
        return _ONES[n]
    if n < 100:
        tens, ones = divmod(n, 10)
        return _TENS[tens] + ("" if ones == 0 else f" {_ONES[ones]}")
    if n < 1000:
        hundreds, rest = divmod(n, 100)
        return f"{_ONES[hundreds]} hundred" + ("" if rest == 0 else f" {_int_words(rest)}")
    return str(n)  # menu prices never get here; leave it to the TTS


def _price_words(amount: str, *, dollar_word: bool) -> str:
    """'19.50' -> 'nineteen fifty', '20' -> 'twenty dollars', '4.00' -> 'four dollars'."""
    whole, _, cents = amount.partition(".")
    cents = (cents + "0")[:2] if cents else ""
    dollars = _int_words(int(whole))
    if not cents or cents == "00":
        return f"{dollars} dollars" if dollar_word else dollars
    if cents.startswith("0"):
        return f"{dollars} oh {_ONES[int(cents)]}"
    return f"{dollars} {_int_words(int(cents))}"


def sanitize_for_speech(text: str) -> str:
    text = _EMOJI.sub("", text)
    text = _LINK.sub(r"\1", text)
    text = _LINE_MARKERS.sub("", text)
    text = _BOLD_ITALIC.sub("", text)
    text = _PRICE_RANGE.sub(
        lambda m: f"{_price_words(m[1], dollar_word=False)} to "
        f"{_price_words(m[2], dollar_word=True)}",
        text,
    )
    text = _PRICE.sub(lambda m: _price_words(m[1], dollar_word=True), text)
    text = _NUMBER_RANGE.sub(r"\1 to \2", text)
    text = text.replace("&", " and ")
    text = _SLASH.sub(" or ", text)
    return re.sub(r"[ \t]{2,}", " ", text)


async def sanitize_stream(text: AsyncIterable[str]) -> AsyncIterator[str]:
    """Yield cleaned text one sentence at a time, flushing the remainder at the end."""
    buffer = ""
    async for chunk in text:
        buffer += chunk
        cut = max(
            (buffer.rfind(b) + len(b) for b in _SENTENCE_BOUNDARIES if b in buffer), default=0
        )
        if cut:
            yield sanitize_for_speech(buffer[:cut])
            buffer = buffer[cut:]
    if buffer:
        yield sanitize_for_speech(buffer)
