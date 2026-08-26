#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


HEADINGS = (
    "## Context and summary",
    "## Affected areas",
    "## Behavior and evidence",
    "## Verification",
    "## Compatibility and migration",
    "## Risk, security, and privacy",
    "## Rollout and rollback",
    "## Reviewer focus",
)
REQUIRED_CONTENT = (
    "## Context and summary",
    "## Behavior and evidence",
    "## Verification",
    "## Compatibility and migration",
    "## Risk, security, and privacy",
    "## Reviewer focus",
)
AFFECTED_AREAS = (
    "Rust daemon/runtime",
    "Server/API",
    "macOS app",
    "Web Admin",
    "MCP, CLI, or agent protocol",
    "Storage, configuration, or schema",
    "Documentation",
    "CI, deployment, or release",
)


def section(body: str, heading: str) -> str | None:
    match = re.search(
        rf"(?ms)^{re.escape(heading)}[ \t]*(?:\r?\n|\Z)(.*?)(?=^##[ \t]|\Z)",
        body,
    )
    return match.group(1) if match else None


def without_fenced_code(text: str) -> str:
    output: list[str] = []
    fence: tuple[str, int] | None = None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^[ \t]{0,3}(`{3,}|~{3,})", line)
        if fence is None:
            if marker:
                fence = (marker.group(1)[0], len(marker.group(1)))
            else:
                output.append(line)
        elif re.fullmatch(
            rf"[ \t]{{0,3}}{re.escape(fence[0])}{{{fence[1]},}}[ \t]*(?:\r?\n)?",
            line,
        ):
            fence = None
    return "".join(output)


def visible(text: str) -> str:
    text = re.sub(r"<!--.*?(?:-->|\Z)", "", text, flags=re.DOTALL)
    text = re.sub(
        r"(?is)<(pre|code|script|style)\b[^>]*>.*?(?:</\1\s*>|\Z)",
        "",
        text,
    )
    return without_fenced_code(text).strip()


def has_answer(text: str) -> bool:
    return bool(re.search(r"\w", visible(text)))


def is_placeholder(text: str) -> bool:
    answer = visible(text)
    answer = re.sub(
        r"(?mi)^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ x]\][ \t]+)?",
        "",
        answer,
    )
    answer = re.sub(r"(?mi)^[ \t]*\[[ x]\][ \t]+", "", answer)
    answer = re.sub(r"[*_`>#]", "", answer)
    answer = re.sub(r"[\s/_.!?,;:—–-]+", "", answer).casefold()
    return answer in {"", "none", "na", "notapplicable"}


def validate(body: str) -> list[str]:
    errors: list[str] = []
    body = visible(body)
    sections = {heading: section(body, heading) for heading in HEADINGS}

    for heading, content in sections.items():
        if content is None:
            errors.append(f"Missing required section: {heading}")

    for heading in REQUIRED_CONTENT:
        content = sections[heading]
        if content is not None and not has_answer(content):
            errors.append(f"Complete the {heading.removeprefix('## ')} section")

    for heading in ("## Context and summary", "## Verification"):
        if is_placeholder(sections[heading] or ""):
            errors.append(f"{heading.removeprefix('## ')} cannot be None")

    affected_areas = sections["## Affected areas"] or ""
    selected = [
        item
        for item in AFFECTED_AREAS
        if re.search(rf"(?mi)^- \[[xX]\] {re.escape(item)}[ \t]*$", affected_areas)
    ]
    if not selected:
        errors.append("Select at least one affected area")

    rollout = visible(sections["## Rollout and rollback"] or "")
    for label in ("Rollout", "Observability", "Rollback"):
        match = re.search(rf"(?mi)^- {label}:[ \t]*(.*)$", rollout)
        if not match or not has_answer(match.group(1)) or is_placeholder(match.group(1)):
            errors.append(f"Complete the {label} field")

    return errors


def valid_sample() -> str:
    return """## Context and summary

Explain the problem and the smallest complete change.

## Affected areas

- [x] Rust daemon/runtime
- [ ] Server/API
- [ ] macOS app
- [ ] Web Admin
- [ ] MCP, CLI, or agent protocol
- [ ] Storage, configuration, or schema
- [ ] Documentation
- [ ] CI, deployment, or release

## Behavior and evidence

None — no user-visible behavior.

## Verification

- `python3 dev/validate-pr-template.py --self-test`

## Compatibility and migration

None.

## Risk, security, and privacy

None.

## Rollout and rollback

- Rollout: Merge through the normal pull request flow.
- Observability: The required status reports pass or fail.
- Rollback: Revert the commit.

## Reviewer focus

None.
"""


def self_test() -> None:
    sample = valid_sample()
    assert not validate(sample)

    unchecked_with_code = sample.replace(
        "- [x] Rust daemon/runtime",
        "- [ ] Rust daemon/runtime\n\n```markdown\n- [x] Rust daemon/runtime\n```",
    )
    invalid = (
        sample.replace("## Context and summary", "## Overview", 1),
        sample.replace("Explain the problem and the smallest complete change.", "<!-- empty -->"),
        sample.replace("- [x] Rust daemon/runtime", "- [ ] Rust daemon/runtime"),
        unchecked_with_code,
        sample.replace("- `python3 dev/validate-pr-template.py --self-test`", "- [x] None."),
        sample.replace("- `python3 dev/validate-pr-template.py --self-test`", "- N / A"),
        sample.replace("- `python3 dev/validate-pr-template.py --self-test`", "- Not-applicable"),
        sample.replace("- Observability: The required status reports pass or fail.", "- Observability:"),
        sample.replace("- Observability: The required status reports pass or fail.", "- Observability: ✅"),
        sample.replace("- Rollback: Revert the commit.", "- Rollback: None"),
        f"<!--\n{sample}\n-->",
        f"<!--\n{sample}",
        f"```markdown\n{sample}\n```",
        f"<pre>\n{sample}\n</pre>",
    )
    assert all(validate(body) for body in invalid)
    print("PR template validator self-test passed.")


def event_body() -> str:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not event_path:
        return os.environ.get("PR_BODY", "")

    payload = json.loads(Path(event_path).read_text())
    pull_request = payload.get("pull_request")
    if not isinstance(pull_request, dict):
        raise ValueError("event payload does not contain a pull_request object")
    body = pull_request.get("body")
    return body if isinstance(body, str) else ""


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if sys.argv[1:]:
        print(f"usage: {Path(sys.argv[0]).name} [--self-test]", file=sys.stderr)
        return 2

    try:
        errors = validate(event_body())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        errors = [f"Unable to read the pull request body: {error}"]

    for error in errors:
        print(f"::error::{error}")
    if errors:
        return 1

    print("PR template validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
