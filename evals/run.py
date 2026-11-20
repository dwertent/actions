# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors

import argparse
import asyncio
from copy import deepcopy
from difflib import unified_diff
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import yaml
from nemo_evaluator import EvalEnvironment, SeedResult, SolveResult, VerifyResult, run_evaluation
from nemo_evaluator.engine import write_all


ROOT = Path(__file__).resolve().parents[1]
ACTION = "verify-commit-signatures/action.yaml"
README = "verify-commit-signatures/README.md"
MODEL = "gpt-6.2-sol"

QUOTA_REMEDIES = {
    "insufficient_quota": "Check API billing, available credits, and usage limits.",
    "credit_balance_exhausted": "Check the organization's prepaid API credit balance.",
    "project_spend_limit_exceeded": "Check the project's API spend limit.",
    "organization_spend_limit_exceeded": "Check the organization's API spend limit.",
    "organization_usage_limit_exceeded": "Check the organization's approved API usage limit.",
}
RATE_LIMIT_CODES = {"rate_limit_error", "rate_limit_exceeded", "slow_down"}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True)


def review_diff(case_id, source, replacement, expected):
    before, after = replacement
    if source.count(before) != 1:
        raise ValueError(f"{case_id}: fixture replacement must match exactly once")
    updated = source.replace(before, after, 1)
    original_default = yaml.safe_load(source)["inputs"]["max-commits"]["default"]
    updated_default = yaml.safe_load(updated)["inputs"]["max-commits"]["default"]
    if expected["rule"]:
        cited_line = updated.splitlines()[expected["line"] - 1]
        if (original_default, updated_default, cited_line) != (
            expected["old_default"], expected["new_default"], after,
        ):
            raise ValueError(f"{case_id}: expected finding does not match the pinned fixture")
    elif original_default != updated_default:
        raise ValueError(f"{case_id}: the review control changes the default")
    return "".join(unified_diff(
        source.splitlines(keepends=True),
        updated.splitlines(keepends=True),
        f"a/{ACTION}", f"b/{ACTION}",
    ))


def load_cases():
    registry = json.loads((ROOT / "evals/cases.json").read_text())
    revision = registry["fixture_revision"]
    files = {path: git("show", f"{revision}:{path}") for path in (ACTION, README)}
    rules = (ROOT / "CONTRIBUTING.md").read_text()
    rule_ids = set(re.findall(r"^\s*- \*\*([A-Z]\d+)\.\*\*", rules, re.MULTILINE))
    cases = registry["cases"]
    if not cases or len({case["id"] for case in cases}) != len(cases):
        raise ValueError("Eval IDs must be unique and the suite must contain at least one case")

    for case in cases:
        expected = case["expected"]
        case["files"] = files
        if case["skill"] == "review-action":
            case["diff"] = review_diff(case["id"], files[ACTION], case["replace"], expected)
            required_rules = {expected["rule"]} if expected["rule"] else set()
        elif case["skill"] == "add-action":
            required_rules = set(expected["rules"])
        elif case["skill"] == "write-evals":
            labels = {expected["regression"]: expected["finding"], expected["control"]: {"rule": None}}
            if len(labels) != 2 or labels.keys() != case["proposals"].keys():
                raise ValueError(f"{case['id']}: the review eval needs a regression and a control")
            case["diffs"] = {
                name: review_diff(case["id"], files[ACTION], replacement, labels[name])
                for name, replacement in case["proposals"].items()
            }
            required_rules = {expected["finding"]["rule"]}
        else:
            raise ValueError(f"{case['id']}: unsupported eval skill")
        if missing := required_rules - rule_ids:
            raise ValueError(f"{case['id']}: update eval rule references for {', '.join(sorted(missing))}")
        case["skill_text"] = (ROOT / ".agents/skills" / case["skill"] / "SKILL.md").read_text()
    return cases


def seed_case(case, with_skill):
    instructions = "\n\n".join((ROOT / path).read_text() for path in ("AGENTS.md", "CONTRIBUTING.md"))
    if with_skill:
        instructions += "\n\n" + case["skill_text"]
    if case["skill"] == "review-action":
        task = {key: case[key] for key in ("prompt", "pr_title", "pr_description", "diff")}
        task["files"] = case["files"]
        task["response_format"] = (
            'Return a JSON object with a "findings" array. Each item has a string "rule", a string "path", '
            'an integer "line" in the proposed change, and strings "before", "after", and "evidence" '
            'describing the base behavior, proposed behavior, and impact. Only report compatibility findings.'
        )
    elif case["skill"] == "write-evals":
        task = {
            "prompt": case["prompt"],
            "files": case["files"],
            "proposals": case["diffs"],
            "response_format": (
                'Return a JSON object with "cases" mapping both proposal IDs to their grading expectations. '
                'For each proposal, give "rule" as a string if a finding is required, or null if the reviewer '
                'should return no findings. A required finding also needs the integer "line" in the proposed '
                'file and the string values "old_default" and "new_default".'
            ),
        }
    else:
        task = {
            "prompt": case["prompt"],
            "files": case["files"],
            "response_format": (
                'Return a JSON object with "files" mapping each edited path to the entire file contents, '
                'and "pr_title" containing the suggested title. Work from the supplied files.'
            ),
        }
    return SeedResult(
        prompt=json.dumps(task),
        system=instructions,
        expected_answer=case["id"],
        metadata={"case_id": case["id"], "category": case["skill"]},
    )


def grade_review(expected, findings):
    fields = {"rule": str, "path": str, "line": int, "before": str, "after": str, "evidence": str}
    if not isinstance(findings, list) or any(
        not isinstance(finding, dict) or any(
            type(finding.get(field)) is not field_type for field, field_type in fields.items()
        )
        for finding in findings
    ):
        raise ValueError("Review response has invalid findings")
    if expected["rule"] is None:
        return {"no_compatibility_false_alarm": not findings}
    matches = [finding for finding in findings if finding["rule"] == expected["rule"]]
    finding = matches[0] if len(matches) == 1 else {}
    evidence = finding.get("evidence", "")
    return {
        "compatibility_finding_reported": len(matches) == 1,
        "changed_default_cited": (finding.get("path"), finding.get("line")) == (ACTION, expected["line"]),
        "before_and_after_defaults_explained": "max-commits" in evidence and all(
            re.search(rf"\b{re.escape(expected[value])}\b", finding.get(field, ""))
            for field, value in (("before", "old_default"), ("after", "new_default"))
        ),
    }


def grade_eval_draft(expected, cases):
    if not isinstance(cases, dict) or cases.keys() != {expected["regression"], expected["control"]}:
        raise ValueError("Eval draft must grade both supplied proposals")
    fields = {"rule": str, "line": int, "old_default": str, "new_default": str}
    for specification in cases.values():
        if not isinstance(specification, dict) or "rule" not in specification or (
            specification["rule"] is not None and any(
                type(specification.get(field)) is not field_type for field, field_type in fields.items()
            )
        ):
            raise ValueError("Eval draft has an invalid grading expectation")
    finding = expected["finding"]
    reference_review = [{
        "rule": finding["rule"], "path": ACTION, "line": finding["line"],
        "before": finding["old_default"], "after": finding["new_default"],
        "evidence": "The new max-commits default rejects pull requests the old default accepted.",
    }]
    regression = cases[expected["regression"]]
    control = cases[expected["control"]]
    return {
        "regression_accepts_correct_review": all(grade_review(regression, reference_review).values()),
        "regression_rejects_missed_finding": not all(grade_review(regression, []).values()),
        "control_accepts_clean_review": all(grade_review(control, []).values()),
        "control_rejects_false_alarm": not all(grade_review(control, reference_review).values()),
    }


def grade(case, response):
    if not isinstance(response, dict):
        raise ValueError("Response is not a JSON object")
    expected = case["expected"]
    if case["skill"] == "review-action":
        return grade_review(expected, response.get("findings"))
    if case["skill"] == "write-evals":
        return grade_eval_draft(expected, response.get("cases"))

    files = response.get("files")
    title = response.get("pr_title")
    if not isinstance(files, dict) or not isinstance(title, str) or any(
        not isinstance(content, str) for content in files.values()
    ):
        raise ValueError("Authoring response has invalid files or title")
    original = yaml.safe_load(case["files"][ACTION])
    candidate = yaml.safe_load(files.get(ACTION, ""))
    candidate_inputs = candidate.get("inputs") if isinstance(candidate, dict) else None
    candidate_limit = candidate_inputs.get("max-commits") if isinstance(candidate_inputs, dict) else None
    new_default = candidate_limit.get("default") if isinstance(candidate_limit, dict) else None
    preserved = deepcopy(original)
    preserved["inputs"]["max-commits"].pop("default")
    if isinstance(candidate_limit, dict):
        candidate_limit.pop("default", None)
    original_default = original["inputs"]["max-commits"]["default"]
    expected_readme = case["files"][README].replace(
        f"| `{original_default}` |", f"| `{expected['default']}` |", 1
    )
    return {
        "only_requested_files_edited": set(files) == {ACTION, README},
        "action_default_updated": new_default == expected["default"],
        "other_action_metadata_preserved": candidate == preserved,
        "readme_default_updated": files.get(README, "").strip() == expected_readme.strip(),
        "breaking_change_marked": bool(re.match(r"^[a-z]+(?:\([^\n()]+\))?!: \S", title)),
    }


class SkillBenchmark(EvalEnvironment):
    name = "actions-skills"

    def __init__(self, with_skill):
        super().__init__()
        self.dataset = load_cases()
        self.cases = {case["id"]: case for case in self.dataset}
        self.with_skill = with_skill

    async def seed(self, idx):
        return seed_case(self.dataset[idx], with_skill=self.with_skill)

    async def verify(self, response, expected, **metadata):
        try:
            checks = grade(self.cases[expected], json.loads(response))
        except (ValueError, yaml.YAMLError):
            return VerifyResult(
                reward=0.0,
                scoring_details={"status": "execution_error", "error": "invalid model response"},
            )
        return VerifyResult(reward=float(all(checks.values())), scoring_details={"checks": checks})


def request_response(task, model, key):
    payload = {
        "model": model,
        "instructions": task.system,
        "input": task.prompt,
        "text": {"format": {"type": "json_object"}},
        "reasoning": {"effort": "low"},
        "max_output_tokens": 4096,
        "store": False,
    }
    request = Request(
        "https://api.openai.com/v1/responses",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=90) as result:
        response = json.load(result)
    if response.get("status") != "completed":
        raise ValueError("Model response did not complete")
    texts = [
        content["text"]
        for item in response["output"] if item["type"] == "message"
        for content in item["content"] if content["type"] == "output_text"
    ]
    if len(texts) != 1:
        raise ValueError("Expected exactly one model response, with no refusal")
    return texts[0]


def describe_http_error(error):
    if error.code != 429:
        return f"model API HTTP {error.code}", False
    try:
        with error:
            body = json.loads(error.read(16_384))
    except (ValueError, OSError):
        body = None
    detail = body.get("error") if isinstance(body, dict) else None
    codes = [detail.get(field) for field in ("code", "type")] if isinstance(detail, dict) else []
    recognized_codes = [code for code in codes if isinstance(code, str)]
    for code in recognized_codes:
        if code in QUOTA_REMEDIES:
            return f"model API HTTP 429, {code}. {QUOTA_REMEDIES[code]}", True
    if RATE_LIMIT_CODES.intersection(recognized_codes):
        return "model API HTTP 429, temporary rate limit. Wait before rerunning and check API rate limits.", False
    return "model API HTTP 429, rate limit or quota. Check API usage and billing before rerunning.", False


class ResponsesSolver:
    """Send a NeMo task to the OpenAI Responses API."""

    def __init__(self, model, key):
        self.model = model
        self.key = key
        self.quota_blocked = False

    async def solve(self, task):
        if self.quota_blocked:
            return SolveResult(response="", reward=0.0, scoring_details={"status": "skipped"})
        try:
            response = await asyncio.to_thread(request_response, task, self.model, self.key)
        except HTTPError as error:
            detail, self.quota_blocked = describe_http_error(error)
        except (URLError, TimeoutError, ValueError, KeyError, TypeError):
            detail = "unavailable or invalid model response"
        else:
            return SolveResult(response=response)
        return SolveResult(
            response="", reward=0.0, scoring_details={"status": "execution_error", "error": detail}
        )


def main():
    parser = argparse.ArgumentParser(description="Evaluate GitHub Actions skills with NVIDIA NeMo Evaluator.")
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--output-dir", type=Path, help="Write NeMo reports to this directory.")
    parser.add_argument(
        "--without-skills", action="store_true", help="Run a matched baseline without loading the target skill."
    )
    args = parser.parse_args()
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        parser.exit(2, "Set OPENAI_API_KEY to run the live skill evals. See evals/README.md.\n")

    config = {
        "model": args.model,
        "checkout": git("rev-parse", "HEAD").strip(),
        "with_skills": not args.without_skills,
    }
    benchmark = SkillBenchmark(with_skill=config["with_skills"])
    print(f"Model {config['model']} | checkout {config['checkout']} | with skills: {config['with_skills']}")
    bundle = asyncio.run(run_evaluation(
        benchmark, ResponsesSolver(args.model, key), config=config, max_concurrent=1, max_system_retries=1,
    ))
    if args.output_dir is not None:
        write_all(bundle, args.output_dir)

    results = bundle["_results"]
    if {result["metadata"]["case_id"] for result in results} != benchmark.cases.keys():
        print("Execution error: NeMo returned an incomplete set of case results.")
        return 2
    failed, errors, skipped = 0, 0, 0
    for result in sorted(results, key=lambda row: row["problem_idx"]):
        case_id = result["metadata"]["case_id"]
        details = result["scoring_details"]
        if details.get("status") == "skipped":
            skipped += 1
        elif "error" in details:
            print(f"{case_id}: execution error ({details['error']})")
            errors += 1
        else:
            for check, passed in details["checks"].items():
                print(f"{case_id}: {'PASS' if passed else 'FAIL'} {check}")
            failed += result["reward"] != 1.0
    passed = len(results) - failed - errors - skipped
    print(f"{passed}/{len(results)} cases passed, {failed} failed, {errors} execution errors, {skipped} skipped")
    return 2 if errors or skipped else int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())
