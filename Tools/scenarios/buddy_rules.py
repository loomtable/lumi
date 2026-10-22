"""Rules the eval tools share with the app, in one place.

- `start(utterance)`: the same decision as BuddyBridge's `Router.start` with routing Auto and a
  fresh conversation. "research…" and "go deep…" never reach Quick in the product, so they are
  not Quick routing cases; "quick answer…" reaches Quick with `<handoff>off</handoff>`.
- `parse_block(text)`: the last fenced ```buddy block, as BuddyBlockExtractor reads it.
- `headline_words(say)`: words in say's first sentence (at most 15), splitting
  sentences the way a reader would: decimals, abbreviations and file names stay whole.
"""
import json
import re
import unicodedata


def _strip_punct(text):
    """Trim whitespace and any Unicode punctuation from both ends (as Swift's .punctuationCharacters)."""
    def edge(ch):
        return ch.isspace() or unicodedata.category(ch).startswith("P")
    start, end = 0, len(text)
    while start < end and edge(text[start]):
        start += 1
    while end > start and edge(text[end - 1]):
        end -= 1
    return text[start:end]


def _said_first(said, phrase):
    if not said.startswith(phrase):
        return False
    rest = said[len(phrase):]
    return not rest or not rest[0].isalnum()


def start(utterance):
    """'research' | 'quick-noh' (quick, handoff off) | 'deep' | 'deeper' | 'quick'."""
    said = _strip_punct(utterance.lower())
    if _said_first(said, "research"):
        return "research"
    if _said_first(said, "go deeper"):
        return "deeper"
    if _said_first(said, "quick answer"):
        return "quick-noh"
    if _said_first(said, "go deep") or _said_first(said, "think hard"):
        return "deep"
    return "quick"


_FENCE = re.compile(r"(?:^|\n)```buddy[ \t]*\r?\n(.*?)\r?\n```[ \t]*(?:\r?\n|$)", re.S | re.I)


def parse_block(text):
    """The last ```buddy block as a dict, or None when there is none or it doesn't decode or
    lacks `say` (the same validity BuddyBlock needs)."""
    blocks = _FENCE.findall(text or "")
    if not blocks:
        return None
    try:
        block = json.loads(blocks[-1])
    except ValueError:
        return None
    if not isinstance(block, dict) or not isinstance(block.get("say"), str):
        return None
    for key in ("card_html", "insert"):
        if block.get(key) is not None and not isinstance(block[key], str):
            return None
    return block


def lane(block):
    """'quick' | 'deep' | 'research' from a valid block (handoff compared case-insensitively)."""
    handoff = block.get("handoff")
    handoff = handoff.lower() if isinstance(handoff, str) else None
    return handoff if handoff in ("deep", "research") else "quick"


def shape(block):
    value = block.get("shape")
    return value.lower() if isinstance(value, str) else None


# Never end a sentence: they introduce what follows.
_NEVER_END = {"e.g", "i.e", "vs", "mr", "mrs", "ms", "dr", "st", "no", "fig", "approx", "jr", "sr", "dept", "cf"}
# End a sentence only when the next word starts with a capital ("…ends at 5 p.m. Then…").
_CAN_END = {"etc", "a.m", "p.m", "inc", "ltd", "co", "est", "min", "max"}


def _stem(token):
    return token.strip("\"'“”‘’()[]").rstrip(".").lstrip("\"'“‘([").lower()


def _is_initial(token):
    core = token.strip("\"'“”‘’()[]")
    return len(core) == 2 and core[0].isalpha() and core[0].isupper() and core[1] == "."


def first_sentence(say):
    """Text up to the first sentence end: . ! ? … followed by whitespace or the end of `say`.
    A period doesn't end the sentence after an abbreviation that never ends one ("e.g."), after
    one that can ("etc.", "p.m.") or a dotted acronym ("I.R.S.", "Ph.D.") when the next word is
    lower case, or after a single capital initial that is part of a name ("J. R. R. Tolkien",
    "by J. Smith"). Decimals and file names ("3.5", "index.ts") have no space after the dot, so
    they never end one."""
    words = say.split()
    for i, tok in enumerate(words):
        core = tok.rstrip("\"'”’)]")
        if not core or core[-1] not in ".!?…":
            continue
        if i == len(words) - 1:
            break
        if core[-1] == ".":
            nxt = words[i + 1].lstrip("\"'“‘([")
            next_upper = bool(nxt) and nxt[0].isupper()
            stem = _stem(core)
            prev_num = i > 0 and words[i - 1][-1:].isdigit()
            # "Ms. Lee" never ends a sentence; "38 ms." (a unit after a number) can.
            if stem in _NEVER_END and not (stem == "ms" and prev_num):
                continue
            if stem == "ms" and prev_num and not next_upper:
                continue
            if (stem in _CAN_END or "." in stem) and not next_upper:
                continue
            if _is_initial(core):
                prev = words[i - 1] if i > 0 else ""
                in_run = _is_initial(prev) or (i + 1 < len(words) and _is_initial(words[i + 1]))
                # "by J. Smith", "Ask J. Smith" (sentence start), but not "Plan A. It…".
                before_name = next_upper and (i <= 1 or not prev or prev[0].islower())
                if in_run or before_name:
                    continue
        return " ".join(words[: i + 1])
    return " ".join(words)


def headline_words(say):
    return len(first_sentence(say).split())
