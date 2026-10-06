"""Token-preserving Lua source utilities; no third-party Python dependencies.

This is a lexer, not a Lua parser. Lua itself validates generated chunks in tests.
Offsets let release generation remove comments without touching string literals.
"""

from dataclasses import dataclass
import re


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int


LONG_OPEN = re.compile(r"\[(=*)\[")
NUMBER = re.compile(
    r"(?:0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)(?:[pP][+-]?\d+)?"
    r"|(?:\d+\.?(?!\.)\d*|\d+|\.\d+)(?:[eE][+-]?\d+)?)"
)
NAME = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
OPERATORS = ("...", "..", "//", "<<", ">>", "==", "~=", "<=", ">=", "::")


def _long_end(source, offset):
    match = LONG_OPEN.match(source, offset)
    if not match:
        return None
    closing = "]" + match[1] + "]"
    end = source.find(closing, match.end())
    if end < 0:
        raise ValueError(f"Unterminated long string/comment at {offset}")
    return end + len(closing)


def tokens(source, include_comments=False):
    offset = 0
    while offset < len(source):
        start = offset
        char = source[offset]
        if char.isspace():
            offset += 1
            continue
        if source.startswith("--", offset):
            end = _long_end(source, offset + 2)
            if end is None:
                end = source.find("\n", offset)
                if end < 0:
                    end = len(source)
            offset = end
            if include_comments:
                yield Token("comment", source[start:end], start, end)
            continue
        if char in "\"'":
            offset += 1
            while offset < len(source):
                if source[offset] == "\\":
                    offset += 2
                elif source[offset] == char:
                    offset += 1
                    break
                else:
                    offset += 1
            else:
                raise ValueError(f"Unterminated string at {start}")
            yield Token("string", source[start:offset], start, offset)
            continue
        end = _long_end(source, offset) if char == "[" else None
        if end is not None:
            offset = end
            yield Token("string", source[start:end], start, end)
            continue
        match = NAME.match(source, offset)
        if match:
            offset = match.end()
            yield Token("name", match[0], start, offset)
            continue
        match = NUMBER.match(source, offset)
        if match:
            offset = match.end()
            yield Token("number", match[0], start, offset)
            continue
        operator = next((value for value in OPERATORS if source.startswith(value, offset)), char)
        offset += len(operator)
        yield Token("operator", operator, start, offset)


def executable_tokens(source):
    return [(token.kind, token.text) for token in tokens(source)]


def strip_comments(source):
    segments = []
    cursor = 0
    for token in tokens(source, include_comments=True):
        if token.kind != "comment":
            continue
        segments.append(source[cursor:token.start])
        # Keep token boundaries even when a long comment is inline.
        segments.append("\n" * token.text.count("\n") if "\n" in token.text else " ")
        cursor = token.end
    segments.append(source[cursor:])
    result = "".join(segments)
    if executable_tokens(result) != executable_tokens(source):
        raise ValueError("Comment stripping changed executable tokens")
    return result
