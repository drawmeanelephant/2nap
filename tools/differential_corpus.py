"""Shared inputs, derived only from 2nap's tests and k4o's README/observations."""

from dataclasses import dataclass
import itertools
import json
from pathlib import Path
import random


@dataclass(frozen=True)
class Case:
    name: str
    template: bytes
    data: bytes | None = b"{}"
    expected_status: int | None = None


def case(name, template, data=None, status=None):
    return Case(name, template.encode(), json.dumps(
        {} if data is None else data, ensure_ascii=False, separators=(",", ":")
    ).encode(), status)


def corpus(root: Path):
    # Reuse every existing template, including errors and examples, unchanged.
    for directory in ("fixtures", "fixtures/errors", "examples"):
        for template in sorted((root / directory).glob("*.knap")):
            data = template.with_suffix(".json")
            yield Case(
                template.relative_to(root).as_posix(), template.read_bytes(),
                data.read_bytes() if data.exists() else None,
                1 if directory.endswith("errors") else 0,
            )

    # Inline unit tests in tests.zig, also exercised through both real CLIs.
    units = [
        ("missing", "[{{ nope }}]{% if nope %}Y{% else %}N{% endif %}", {}),
        ("loop-metadata", "{% for x in xs %}{{ loop.index0 }}:{{ loop.index }}:"
         "{{ loop.first }}:{{ loop.last }}:{{ loop.length }};{% endfor %}", {"xs": ["a", "b"]}),
        ("block-newline", "{% if true %}\nA\n{% endif %}\nend", {}),
        ("comment-no-eval", "a{# {{ x }} {% if %} #}b", {}),
    ]
    for name, template, data in units:
        yield case("unit/" + name, template, data, 0)

    values = [None, False, True, 0, -1, 2, 2.0, 1.25, "", "0", "é🐘",
              [], [1, None, "x"], {}, {"p": 1, "q": [2]}]
    for i, value in enumerate(values):
        yield case(f"value/{i}", "[{{ x }}]|{% if x %}T{% else %}F{% endif %}", {"x": value}, 0)
        for j, other in enumerate(values):
            for op in ("==", "!=", "<", "<=", ">", ">=", "contains"):
                yield case(f"compare/{i}/{j}/{op}", "{% if a " + op +
                           " b %}T{% else %}F{% endif %}", {"a": value, "b": other}, 0)
    for name, a, b in [
        ("key-order", {"p": 1, "q": [2]}, {"q": [2.0], "p": 1}),
        ("nested-difference", {"p": [1, {"q": 2}]}, {"p": [1, {"q": 3}]}),
        ("large-integers", 9007199254740992, 9007199254740993),
    ]:
        yield case("equality/" + name, "{% if a == b %}T{% else %}F{% endif %}", {"a": a, "b": b}, 0)
    for i, number in enumerate([0.0, -0.0, 2.0, 0.1, 1e-7, 1e20, 1e21, 1.2345678901234567]):
        yield case(f"number/{i}", "{{ x }}|{{ xs }}", {"x": number, "xs": [number]}, 0)
    for i, a in enumerate([-(2**63), 2**63 - 1, 2**53, 2**53 + 1, 1e-300, 1e300]):
        for j, b in enumerate([-(2**63), 2**63 - 1, 2**53, float(2**53), 2**53 + 1]):
            for op in ("==", "!=", "<", "<=", ">", ">="):
                yield case(f"number/boundary/{i}/{j}/{op}", "{% if a " + op +
                           " b %}T{% else %}F{% endif %}", {"a": a, "b": b}, 0)

    texts = ["", "hello", "é🐘", " *a*_@b@|", 'a"b', "a\nb", "a\rb",
             "a\r\nb", "\n", "a\tb", "a\x00b", "a\\b"]
    filters = ["h1", "h2", "h3", "h4", "h5", "h6", "bold", "italic",
               "code", "blockquote", "codeblock", "link"]
    for filter_name, (i, value) in itertools.product(filters, enumerate(texts + values)):
        suffix = ':"https://example.com/a"' if filter_name == "link" else ""
        yield case(f"filter/{filter_name}/{i}", "before{{ x | " + filter_name +
                   suffix + " }}after", {"x": value})
    for i, url in enumerate(["https://example.com/", "/relative", "#anchor", "mailto:a@b",
                             "ftp://a", "file:/a", "a/b:c", "", "javascript:alert(1)",
                             "JaVaScRiPt:x", "data:text/html,x", "vbscript:x", "a b",
                             'a"b', "a\nb", "a\rb", "a\tb", " javascript:x"]):
        yield case(f"link/url/{i}", '{{ x | link:url }}', {"x": "name", "url": url})
        yield case(f"link/literal/{i}", "{{ x | link:" + json.dumps(url) + " }}", {"x": "name"})
    for i, arg in enumerate(values):
        yield case(f"argument/{i}", "{{ x | link:arg }}", {"x": "name", "arg": arg})
    for name, arg in [("fallback", "unknown"), ("quoted", '"url"'), ("number", "7"), ("negative", "-1"),
                      ("float", "1.5"), ("hyphen", "a-b"), ("dotted", "a.b")]:
        yield case("argument/" + name, "{{ x | link:" + arg + " }}",
                   {"x": "name", "url": "https://example.com/", "a-b": "/path"})
    for name, chain, data in [
        ("italic-heading", "italic | h2", {"x": "title"}),
        ("heading-bold", "h2 | bold", {"x": "title"}),
        ("code-link", 'code | link:"/path"', {"x": "cmd"}),
        ("list-block", "list | codeblock", {"x": ["a", ["b"]]}),
        ("table-block", "table | codeblock", {"x": [["h"], ["v"]]}),
        ("list-bold", "list | bold", {"x": ["a", "b"]}),
    ]:
        yield case("chain/" + name, "{{ x | " + chain + " }}", data)

    lists = [[], ["a"], ["", "b"], [1, None, True, {"p": 1}], ["a", ["b", ["c"]]],
             [[], "a", [], ["b"]], [[[[["too deep"]]]]], ["a\nb"], ["a\rb"],
             ["a|b"], [[[[[]]]]], [None], [False], [7], [{}]]
    for i, value in enumerate(lists + values):
        for name in ("list", "numbered"):
            yield case(f"collection/{name}/{i}", "{{ x | " + name + " }}", {"x": value})
    tables = [[], [[]], [[], []], [["a", "b"]], [["a", "b"], [1, None]], [["a"], ["b", "c"]],
              ["header"], [["header"], "row"], [["a|b"]], [["a\nb"]], [["a\rb"]],
              [["h"], ["a|b"]], [["h"], ["a\nb"]], [[{"x": 1}, [2]], [True, 1.5]],
              [[None]], [[False]], [[7]], [["a|\nb"]], [["h"], []]]
    for i, value in enumerate(tables + values):
        yield case(f"collection/table/{i}", "{{ x | table }}", {"x": value})

    paths = ["author.name", "authors[0].name", 'metadata["article:section"]',
             "authors[9]", 'metadata["missing"]', "First name", "author.First name",
             'metadata["a.b"]', "authors[0]", "missing.path[0]", "x.y", "x[0]",
             "true value", "null value", "作者"]
    data = {"author": {"name": "Ada", "First name": "A"}, "authors": [{"name": "B"}],
            "metadata": {"article:section": "C", "a.b": "D"}, "First name": "E",
            "x": 7, "true value": "T", "null value": "N", "作者": "象"}
    for i, path in enumerate(paths):
        yield case(f"path/{i}", "[{{ " + path + " }}]", data)
    for i, literal in enumerate(['"hello"', '"a\\nb"', '"a\\tb"', '"a\\rb"', '"a\\"b"',
                                 '"a\\\\b"', '"}}"', '"%}"', "true", "false", "null",
                                 "-7", "1.5", "0"]):
        yield case(f"literal/{i}", "{{ " + literal + " }}")
    for i, expression in enumerate([
        "x[01]", "x[ 0 ]", 'x[ "a" ]', "x[0][1]", 'x["a"].b', "x . a",
        "x.a[0]", 'x[""]', 'x["a\\nb"]', "true", "false", "null", "-0",
        "1e3", "1.", "01", '""', '"a\\qb"', '"a\nb"', '"{#comment#}"',
        '"x|y"', '"x:y"', '"x%}y"', '"x}}y"', "x. a", "x .a", "x [0]",
        "x[0] .a", "-1e-3", "1.2e3", "999999999999999999999999",
    ]):
        yield case(f"expression/edge/{i}", "[{{ " + expression + " }}]",
                   {"x": {"a": {"b": "B"}, "": "empty", "anb": "escape"}})
    for i, template in enumerate([
        "{% if true extra %}A{% endif %}", "{% if true %}A{% endif extra %}",
        "{% if true %}A{% else extra %}B{% endif %}",
        "{% for x in xs %}A{% endfor extra %}", "{% if\ntrue %}A{% endif %}",
        "{{ x[abc] }}", "{{ x[0 }}", "{{ x[999999999999999999999999] }}",
        "{{ x | link:1e3 }}", "{{ x | link:true }}", "{{ x | link:null }}",
        "{{ x | link:\"x\" junk }}", "{{ x | link:a b }}", "{% if (true %}A{% endif %}",
        "{% if not %}A{% endif %}", "{% if a == %}A{% endif %}",
        "{% for x in xs junk %}A{% endfor %}",
        "{% if false %}A{% elseif true junk %}B{% endif %}",
        "{%\nif true %}A{% endif %}", "{% if true %}A{% endif\njunk %}",
        "{% if true\nand false %}A{% else %}B{% endif %}",
    ]):
        yield case(f"syntax/edge/{i}", template, {"xs": [1], "x": "X", "true": "/yes", "null": "/null"})
    for i, newline in enumerate(["", "\n", "\r\n", "\r", "\n\n", " \n", "\t\n"]):
        for branch in ("if true", "if false"):
            template = "{% " + branch + " %}" + newline + "A\n{% else %}" + newline + "B\n{% endif %}Z"
            yield case(f"whitespace/{i}/{branch}", template, status=0)
        yield case(f"whitespace/{i}/loop", "{% for x in xs %}" + newline +
                   "{{ x }}\n{% endfor %}Z", {"xs": ["A", "B"]}, 0)
    for i, template in enumerate([
        "", "plain\ntext\r\n", "{ just text }", "a{# first #}b{# second #}c",
        "a{# {# inner #}tail#}b", "{# {{ bad | nonexistent }} #}ok",
        "{% for x in xs %}{{ x }}{% for x in xs %}{{ x }}{% endfor %}{{ x }}{% endfor %}",
        "{% for loop in xs %}{{ loop.index }}{% endfor %}",
        "{% if true %}{% if false %}A{% else %}B{% endif %}{% endif %}",
    ]):
        yield case(f"structure/{i}", template, {"xs": [1, 2]}, 0)

    malformed = ["{{", "{{ }}", "{{ x | }}", "{{ x | nope }}", "{{ x | bold:7 }}",
                 "{{ x | link }}", "{{ x | link: }}", '{{ "unterminated }}',
                 "{{ x[ }}", "{{ x[-1] }}", '{{ x["a" }}', "{{ x. }}", "{{ x || bold }}",
                 "{%", "{% nope %}", "{% if %}", "{% if true %}", "{% endif %}",
                 "{% else %}", "{% endfor %}", "{% for %}", "{% for x xs %}",
                 "{% for x in xs %}", "{# unfinished",
                 "{% if true %}A{% else %}B{% elseif true %}C{% endif %}",
                 "{% if true %}A{% else %}B{% else %}C{% endif %}"]
    for i, template in enumerate(malformed):
        yield case(f"syntax/{i}", "prefix\n" + template, {"xs": [1], "x": "text"}, 1)

    # Reproducible combinations; no random seed or oracle-generated golden files.
    rng = random.Random(0x2A4)
    for i in range(120):
        a, b, c = (rng.choice(values) for _ in range(3))
        op1, op2 = (rng.choice(["and", "or", "&&", "||"]) for _ in range(2))
        expr = rng.choice(["a", "not a", "!a", "(a == b)"]) + " " + op1 + " b " + op2 + " c"
        yield case(f"logic/generated/{i}", "{% if " + expr + " %}T{% elseif not b %}N"
                   "{% else %}F{% endif %}", {"a": a, "b": b, "c": c}, 0)
        yield case(f"loop/generated/{i}", "{% for x in xs %}{{ loop.index }}:"
                   "{% if x %}{{ x }}{% else %}empty{% endif %};{% endfor %}",
                   {"xs": [a, b, c]}, 0)
