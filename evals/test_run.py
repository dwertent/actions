# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors

from contextlib import redirect_stdout
from io import BytesIO, StringIO
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from run import ACTION, README, load_cases, grade, main, seed_case


def responses_result(answer):
    return BytesIO(json.dumps({
        "status": "completed",
        "output": [
            {"type": "reasoning", "summary": []},
            {"type": "message", "content": [{"type": "output_text", "text": json.dumps(answer)}]},
        ],
    }).encode())


class SkillEvalsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = {case["id"]: case for case in load_cases()}

    def test_review_detects_changed_default_at_the_source_line(self):
        case = self.cases["review-undeclared-default-change"]
        finding = {
            "rule": "C1", "path": ACTION, "line": 8,
            "before": "250 commits", "after": "200 commits",
            "evidence": "The lower max-commits default rejects some PRs accepted by the current release.",
        }
        self.assertTrue(all(grade(case, {"findings": [finding]}).values()))
        reversed_finding = dict(finding, before="200 commits", after="250 commits")
        self.assertFalse(grade(case, {"findings": [reversed_finding]})["before_and_after_defaults_explained"])
        finding["line"] = 7
        self.assertFalse(all(grade(case, {"findings": [finding]}).values()))
        self.assertFalse(all(grade(case, {"findings": []}).values()))

    def test_review_rejects_false_alarms_on_the_passing_control(self):
        case = self.cases["review-description-only"]
        self.assertTrue(all(grade(case, {"findings": []}).values()))
        false_alarm = {
            "rule": "C1", "path": ACTION, "line": 6,
            "before": "250", "after": "200", "evidence": "Default changed.",
        }
        self.assertFalse(all(grade(case, {"findings": [false_alarm]}).values()))

    def test_author_updates_artifacts_and_preserves_the_interface(self):
        case = self.cases["author-default-and-documentation"]
        response = {
            "files": {
                ACTION: case["files"][ACTION].replace('default: "250"', 'default: "200"'),
                README: case["files"][README].replace('| `250` |', '| `200` |'),
            },
            "pr_title": "feat(verify-commit-signatures)!: lower the default limit",
        }
        self.assertTrue(all(grade(case, response).values()))
        response["files"][ACTION] = response["files"][ACTION].replace("  token:", "  access-token:")
        self.assertFalse(grade(case, response)["other_action_metadata_preserved"])
        response["files"][README] = case["files"][README]
        self.assertFalse(grade(case, response)["readme_default_updated"])
        response["pr_title"] = "feat(verify-commit-signatures): lower the default limit"
        self.assertFalse(grade(case, response)["breaking_change_marked"])

    def test_candidate_request_uses_current_guidance_with_no_answer_key(self):
        case = self.cases["review-undeclared-default-change"]
        candidate = seed_case(case, with_skill=True)
        baseline = seed_case(case, with_skill=False)
        self.assertIn("# Contributing to zarf-dev/actions", candidate.system)
        self.assertIn("# Repository Guidelines", baseline.system)
        self.assertIn("# Review a change against the contributing rules", candidate.system)
        self.assertNotIn("# Review a change against the contributing rules", baseline.system)
        self.assertEqual(candidate.prompt, baseline.prompt)
        self.assertNotIn("expected", json.loads(candidate.prompt))

    def test_invalid_review_output_is_an_execution_failure(self):
        case = self.cases["review-description-only"]
        with self.assertRaises(ValueError):
            grade(case, {"findings": [{"rule": "C1"}]})

    def test_authored_eval_accepts_correct_reviews_and_rejects_review_mistakes(self):
        case = self.cases["author-a-review-eval"]
        draft = {"cases": {
            "proposal-a": {"rule": None},
            "proposal-b": {"rule": "C1", "line": 8, "old_default": "250", "new_default": "175"},
        }}
        self.assertTrue(all(grade(case, draft).values()))
        draft["cases"]["proposal-b"]["line"] = 7
        self.assertFalse(grade(case, draft)["regression_accepts_correct_review"])
        draft["cases"]["proposal-b"] = {"rule": None}
        self.assertFalse(grade(case, draft)["regression_rejects_missed_finding"])
        draft["cases"]["proposal-a"] = {"rule": "C1", "line": 8, "old_default": "250", "new_default": "175"}
        self.assertFalse(grade(case, draft)["control_rejects_false_alarm"])

        task = seed_case(case, with_skill=True)
        self.assertIn("# Write evals for GitHub Actions skills", task.system)
        inputs = json.loads(task.prompt)
        self.assertEqual(set(inputs["proposals"]), {"proposal-a", "proposal-b"})
        for private in ("expected", "regression", "control"):
            self.assertNotIn(private, inputs)

    def test_quota_error_stops_live_run_and_omits_raw_provider_message(self):
        for code in ("insufficient_quota", "credit_balance_exhausted", "project_spend_limit_exceeded"):
            with self.subTest(code=code):
                body = json.dumps({"error": {"code": code, "message": "private diagnostic"}}).encode()
                with (
                    patch.dict(os.environ, {"OPENAI_API_KEY": "test-key"}),
                    patch.object(sys, "argv", ["run.py"]),
                    patch("run.urlopen", side_effect=HTTPError(
                        "https://api.openai.com/v1/responses", 429, "quota error", {}, BytesIO(body)
                    )) as endpoint,
                    redirect_stdout(StringIO()) as log,
                ):
                    self.assertEqual(main(), 2)
                self.assertEqual(endpoint.call_count, 1)
                request = json.loads(endpoint.call_args.args[0].data)
                self.assertEqual(request["model"], "gpt-6.2-sol")
                self.assertIn(code, log.getvalue())
                self.assertIn("3 skipped", log.getvalue())
                self.assertNotIn("private diagnostic", log.getvalue())

    def test_live_run_reports_regressions_separately_from_provider_errors(self):
        with (
            TemporaryDirectory() as results_dir,
            patch.dict(os.environ, {"OPENAI_API_KEY": "test-key"}),
            patch.object(sys, "argv", ["run.py", "--model", "test-model", "--output-dir", results_dir]),
            patch("run.urlopen", side_effect=[
                responses_result({"findings": []}), responses_result({"findings": []}),
                HTTPError(
                    "https://api.openai.com/v1/responses", 429, "rate limit", {},
                    BytesIO(b'{"error":{"type":"rate_limit_error","code":"slow_down"}}'),
                ),
                HTTPError("https://api.openai.com/v1/responses", 429, "unknown", {}, BytesIO(b"gateway response")),
            ]) as endpoint,
            redirect_stdout(StringIO()) as log,
        ):
            self.assertEqual(main(), 2)
            bundle_path, = Path(results_dir).glob("eval-*.json")
            bundle = json.loads(bundle_path.read_text())
            self.assertEqual(bundle["sdk_version"], "0.3.0")
            self.assertEqual(bundle["benchmark"]["samples"], 4)
            self.assertEqual(bundle["config"]["model"], "test-model")
            self.assertNotIn("test-key", bundle_path.read_text())
            results = [
                json.loads(line)
                for line in (Path(results_dir) / "results.jsonl").read_text().splitlines()
            ]
            self.assertEqual({result["metadata"]["case_id"] for result in results}, set(self.cases))
            control = next(result for result in results if result["metadata"]["case_id"] == "review-description-only")
            self.assertEqual(control["reward"], 1.0)

        self.assertEqual(endpoint.call_count, 4)
        request = endpoint.call_args_list[0].args[0]
        self.assertEqual(request.full_url, "https://api.openai.com/v1/responses")
        self.assertIs(json.loads(request.data)["store"], False)
        self.assertIn("temporary rate limit", log.getvalue())
        self.assertIn("rate limit or quota", log.getvalue())
        self.assertIn("1/4 cases passed, 1 failed, 2 execution errors", log.getvalue())

    def test_nemo_run_gates_all_four_cases(self):
        source = self.cases["author-default-and-documentation"]["files"]
        answers = [
            {"findings": [{
                "rule": "C1", "path": ACTION, "line": 8, "before": "250", "after": "200",
                "evidence": "The lower max-commits default rejects previously accepted PRs.",
            }]},
            {"findings": []},
            {
                "files": {
                    ACTION: source[ACTION].replace('default: "250"', 'default: "200"'),
                    README: source[README].replace('| `250` |', '| `200` |'),
                },
                "pr_title": "feat(verify-commit-signatures)!: lower the default limit",
            },
            {"cases": {
                "proposal-a": {"rule": None},
                "proposal-b": {"rule": "C1", "line": 8, "old_default": "250", "new_default": "175"},
            }},
        ]
        incorrect = [*answers[:-1], {"cases": {"proposal-a": {"rule": None}, "proposal-b": {"rule": None}}}]
        for replay, exit_code, result in ((answers, 0, "PASS"), (incorrect, 1, "FAIL")):
            with (
                self.subTest(exit_code=exit_code),
                patch.dict(os.environ, {"OPENAI_API_KEY": "test-key"}),
                patch.object(sys, "argv", ["run.py", "--without-skills"]),
                patch("run.urlopen", side_effect=map(responses_result, replay)) as endpoint,
                redirect_stdout(StringIO()) as log,
            ):
                self.assertEqual(main(), exit_code)
                self.assertEqual(endpoint.call_count, 4)
                self.assertIn(f"{4 - exit_code}/4 cases passed", log.getvalue())
                self.assertIn(f"author-a-review-eval: {result} regression_rejects_missed_finding", log.getvalue())
                request = json.loads(endpoint.call_args_list[-1].args[0].data)
                self.assertNotIn("# Write evals for GitHub Actions skills", request["instructions"])
