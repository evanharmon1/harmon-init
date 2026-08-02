"""All GitHub access — every read and every mutation lives here, nowhere else.

Write contract (docs/architecture/foreman.md): foreman MAY create/push its own
branches, open DRAFT PRs, promote its OWN draft PR to ready for review once its
readiness gate passes, edit its OWN PRs and their foreman-namespace
labels, create/edit the single marker-identified status comment per unit,
resolve review threads it dispositioned, post human-approved preflight
correction comments, and idempotently ensure its label definitions exist.

Foreman MUST NEVER: merge anything, close/reopen issues, edit issue
titles/bodies/milestones, edit or delete human or third-party comments,
write custom-field values / issue types / dependency edges, or touch repo
settings. Those operations are deliberately absent from this module, and
tests/test_write_contract.py greps this file to keep them absent.

Reads use `gh` JSON output (gh >= 2.96 exposes blockedBy, issueType,
subIssues, parent, closedByPullRequestsReferences); review threads are the
one GraphQL-only read.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

from foreman.config import Config
from foreman.util import ForemanError, run

Runner = Callable[[list[str], str | None], tuple[int, str, str]]

STATUS_MARKER = "<!-- foreman:unit-status -->"

# GitHub's own wording when a repository cannot open drafts (private repos on
# unpaid plans). Matched case-folded against the error text.
UNSUPPORTED_DRAFT_ERROR = "draft pull requests are not supported"

# Labels foreman idempotently ensures and is allowed to apply to its own PRs.
FOREMAN_LABELS = {
    "foreman-dispatched": ("1D76DB", "PR opened by foreman for a dispatched unit"),
    "ready-to-merge": (
        "5319E7",
        "Green, adjudicated, mergeable - awaiting human merge",
    ),
}

ISSUE_FIELDS = (
    "number,title,body,state,stateReason,labels,milestone,url,issueType,"
    "parent,subIssues,blockedBy,closedByPullRequestsReferences"
)

PR_LIST_FIELDS = (
    "number,title,body,url,state,isDraft,headRefName,baseRefName,labels,author"
)

REVIEW_THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          comments(first: 50) {
            nodes { author { login } authorAssociation body url }
          }
        }
      }
    }
  }
}
"""

RESOLVE_THREAD_MUTATION = """
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
"""


def _subprocess_runner(argv: list[str], input_text: str | None) -> tuple[int, str, str]:
    proc = run(["gh", *argv], input_text=input_text, check=False)
    return proc.returncode, proc.stdout, proc.stderr


class Gh:
    """Thin `gh` transport; tests inject a fake runner here."""

    def __init__(self, runner: Runner | None = None):
        self._runner = runner or _subprocess_runner

    def call(
        self, args: list[str], *, input_text: str | None = None, check: bool = True
    ) -> str:
        rc, out, err = self._runner(args, input_text)
        if check and rc != 0:
            raise ForemanError(
                f"gh {' '.join(args)} failed ({rc}): {err.strip() or out.strip()}"
            )
        return out

    def ok(self, args: list[str]) -> bool:
        rc, _out, _err = self._runner(args, None)
        return rc == 0

    def json(self, args: list[str], *, input_text: str | None = None) -> Any:
        out = self.call(args, input_text=input_text)
        try:
            return json.loads(out) if out.strip() else None
        except json.JSONDecodeError as exc:
            raise ForemanError(f"gh {' '.join(args)}: unparseable JSON output") from exc


class GitHub:
    """Repository-scoped GitHub facade enforcing the write contract."""

    def __init__(self, gh: Gh, cfg: Config):
        self.gh = gh
        self.cfg = cfg
        self.read_only = False
        self._identity_ok = False
        self._cache: dict[str, Any] = {}
        self._issue_cache: dict[int, dict] = {}

    # ── facts ────────────────────────────────────────────────────────

    def repo(self) -> dict:
        if "repo" not in self._cache:
            self._cache["repo"] = self.gh.json(
                [
                    "repo",
                    "view",
                    "--json",
                    "nameWithOwner,owner,name,defaultBranchRef,visibility",
                ]
            )
        return self._cache["repo"]

    def repo_slug(self) -> str:
        return self.repo()["nameWithOwner"]

    def owner(self) -> str:
        return self.repo()["owner"]["login"]

    def default_branch(self) -> str:
        return self.repo()["defaultBranchRef"]["name"]

    def viewer(self) -> str:
        if "viewer" not in self._cache:
            self._cache["viewer"] = self.gh.call(
                ["api", "user", "--jq", ".login"]
            ).strip()
        return self._cache["viewer"]

    # ── issue reads ──────────────────────────────────────────────────

    def issue(self, number: int, *, fresh: bool = False) -> dict:
        if fresh or number not in self._issue_cache:
            self._issue_cache[number] = self.gh.json(
                ["issue", "view", str(number), "--json", ISSUE_FIELDS]
            )
        return self._issue_cache[number]

    def issue_comments(self, number: int) -> list[dict]:
        """Comments with stable ids + author_association (REST, paginated)."""
        out = self.gh.json(
            [
                "api",
                f"repos/{self.repo_slug()}/issues/{number}/comments",
                "--paginate",
                "--slurp",
            ]
        )
        comments: list[dict] = []
        for page in out or []:
            comments.extend(page)
        return comments

    def milestones(self, state: str = "open") -> list[dict]:
        return (
            self.gh.json(
                [
                    "api",
                    f"repos/{self.repo_slug()}/milestones?state={state}&per_page=100",
                ]
            )
            or []
        )

    def resolve_milestone(self, ident: str) -> dict:
        """Accept a milestone number or exact title; return the milestone."""
        for ms in self.milestones(state="all"):
            if str(ms["number"]) == str(ident) or ms["title"] == ident:
                return ms
        raise ForemanError(f"milestone not found: {ident}")

    def milestone_issue_numbers(self, title: str) -> list[int]:
        rows = (
            self.gh.json(
                [
                    "issue",
                    "list",
                    "--milestone",
                    title,
                    "--state",
                    "all",
                    "--limit",
                    "500",
                    "--json",
                    "number",
                ]
            )
            or []
        )
        return [row["number"] for row in rows]

    # ── PR reads ─────────────────────────────────────────────────────

    def prs(
        self, *, label: str | None = None, head: str | None = None, state: str = "open"
    ) -> list[dict]:
        args = [
            "pr",
            "list",
            "--state",
            state,
            "--limit",
            "200",
            "--json",
            PR_LIST_FIELDS,
        ]
        if label:
            args += ["--label", label]
        if head:
            args += ["--head", head]
        return self.gh.json(args) or []

    def pr_view(self, number: int, fields: str) -> dict:
        return self.gh.json(["pr", "view", str(number), "--json", fields])

    def pr_status(self, number: int) -> dict:
        return self.pr_view(
            number,
            "number,title,body,url,state,isDraft,merged,mergedAt,author,labels,"
            "headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,"
            "reviewDecision,statusCheckRollup",
        )

    def pr_gate_snapshot(self, number: int) -> dict:
        """Every volatile field the readiness gate decides on, read together.

        One call, compared as a unit, so a field cannot go stale between the
        gate's checks and the one-way promotion. Adding a condition to the gate
        means adding it here — not another sequential re-read, which is how
        `reviewDecision` came to be checked once at the top and never refreshed.
        """
        return self.pr_view(number, "state,isDraft,headRefOid,reviewDecision")

    def review_threads(self, number: int) -> list[dict]:
        out = self.gh.json(
            [
                "api",
                "graphql",
                "-f",
                f"query={REVIEW_THREADS_QUERY}",
                "-F",
                f"owner={self.owner()}",
                "-F",
                f"name={self.repo()['name']}",
                "-F",
                f"number={number}",
            ]
        )
        if not isinstance(out, dict) or out.get("errors"):
            raise ForemanError(
                f"review threads: indeterminate GraphQL response for PR #{number}"
            )
        try:
            nodes = out["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
        except (KeyError, TypeError) as exc:
            raise ForemanError(
                f"review threads: unexpected GraphQL shape for PR #{number}"
            ) from exc
        if not isinstance(nodes, list) or not all(
            isinstance(thread, dict) for thread in nodes
        ):
            raise ForemanError(f"review threads: invalid thread list for PR #{number}")
        return nodes

    def review_authors(self, number: int, commit: str) -> set[str]:
        """Logins that submitted a review of exactly `commit`.

        Reviews only. An inline comment's `commit_id` is re-anchored to the
        latest commit when its line survives a push, so a comment from an older
        review reads as current — observed on harmon-init#520, where a review of
        `c56103a` carried an inline comment stamped with the newer head.
        """
        # --slurp with --paginate, as issue_comments() does: without it `gh`
        # emits one JSON array per page and Gh.json's single json.loads() fails
        # on the second, so a PR with enough reviews to paginate would make this
        # gate escalate forever instead of reading them.
        pages = (
            self.gh.json(
                [
                    "api",
                    f"repos/{self.repo_slug()}/pulls/{number}/reviews",
                    "--paginate",
                    "--slurp",
                ]
            )
            or []
        )
        rows = [row for page in pages for row in page]
        return {
            login
            for login in (
                ((row.get("user") or {}).get("login") or "")
                for row in rows
                if isinstance(row, dict) and row.get("commit_id") == commit
            )
            if login
        }

    def behind_by(self, base: str, head: str) -> int:
        """Commits on `base` that `head` does not have.

        Asked directly instead of inferred from `mergeStateStatus`, because a
        draft reports DRAFT — which masks BEHIND the same way it masks BLOCKED.
        A response without the field raises rather than reading as up to date.
        """
        data = self.gh.json(
            ["api", f"repos/{self.repo_slug()}/compare/{base}...{head}"]
        )
        value = (data or {}).get("behind_by")
        if not isinstance(value, int):
            raise ForemanError(f"compare {base}...{head}: no behind_by in response")
        return value

    def required_checks(self, branch: str) -> set[str]:
        """Check contexts `branch` requires — rulesets and classic protection.

        One endpoint covers both, so this is what the base branch will actually
        enforce at merge time. An empty set means the branch enforces nothing;
        that is a real configuration, not an error, and the caller decides what
        it means. A failed call raises, because "could not ask" must never read
        as "nothing is required".
        """
        rules = self.gh.json(
            ["api", f"repos/{self.repo_slug()}/rules/branches/{branch}"]
        )
        contexts: set[str] = set()
        for rule in rules or []:
            if not isinstance(rule, dict):
                continue
            if rule.get("type") != "required_status_checks":
                continue
            params = rule.get("parameters") or {}
            for check in params.get("required_status_checks") or []:
                context = (check or {}).get("context")
                if context:
                    contexts.add(context)
        return contexts

    def branch_exists_remote(self, branch: str) -> bool:
        return self.gh.ok(["api", f"repos/{self.repo_slug()}/branches/{branch}"])

    def run_log_failed(self, run_url: str) -> str:
        """Failed-step log excerpt for an Actions run URL (best effort)."""
        run_id = run_url.rstrip("/").split("/")[-1]
        if not run_id.isdigit():
            return ""
        rc, out, _err = self.gh._runner(["run", "view", run_id, "--log-failed"], None)
        return out[-20000:] if rc == 0 else ""

    # ── write guard ──────────────────────────────────────────────────

    def _assert_writable(self, action: str) -> None:
        if self.read_only:
            raise ForemanError(
                f"write contract: '{action}' attempted in read-only mode"
            )
        if not self._identity_ok:
            expected = self.cfg.expected_login
            if expected:
                actual = self.viewer()
                if actual != expected:
                    raise ForemanError(
                        f"identity assertion failed: gh is authenticated as '{actual}' "
                        f"but config expects '{expected}' — refusing to write"
                    )
            self._identity_ok = True

    # ── guarded writes (the ENTIRE mutation surface) ─────────────────

    def ensure_labels(self) -> None:
        self._assert_writable("ensure labels")
        for name, (color, desc) in FOREMAN_LABELS.items():
            self.gh.call(
                [
                    "label",
                    "create",
                    name,
                    "--color",
                    color,
                    "--description",
                    desc,
                    "--force",
                ]
            )

    def create_pr(
        self, *, title: str, body: str, head: str, base: str, labels: list[str]
    ) -> str:
        self._assert_writable("create PR")
        # Always a draft: the PR is the agent workbench until the readiness gate
        # promotes it (AGENTS.md, "Dev Loop"). Non-draft is the human handoff,
        # and foreman must never manufacture that at creation time.
        args = [
            "pr",
            "create",
            "--draft",
            "--title",
            title,
            "--body-file",
            "-",
            "--head",
            head,
            "--base",
            base,
        ]
        for label in labels:
            args += ["--label", label]
        try:
            out = self.gh.call(args, input_text=body)
        except ForemanError as exc:
            # Diagnosis only. Match GitHub's specific message, NOT a bare
            # "draft": ForemanError embeds the whole invocation, which always
            # contains `--draft`, so a looser test relabels every creation
            # failure — expired auth, a bad base, a missing label — as a
            # paid-plan limitation and buries the real cause.
            if UNSUPPORTED_DRAFT_ERROR in str(exc).casefold():
                raise ForemanError(
                    "could not open a DRAFT pull request. GitHub restricts draft "
                    "PRs on private repositories to paid plans, and the draft is "
                    "the workbench this lifecycle is built on (AGENTS.md, 'Dev "
                    "Loop'). Make the repository public or upgrade its plan — do "
                    "not drop --draft, which would publish unshepherded agent work "
                    f"as a human handoff. Underlying error: {exc}"
                ) from exc
            raise
        return out.strip().splitlines()[-1] if out.strip() else ""

    def _own_pr_guard(self, number: int, action: str) -> dict:
        pr = self.pr_view(number, "number,author,labels,body")
        if pr["author"]["login"] != self.viewer():
            raise ForemanError(
                f"write contract: '{action}' on PR #{number} not authored by foreman"
            )
        return pr

    def edit_own_pr_body(self, number: int, body: str) -> None:
        self._assert_writable("edit own PR body")
        self._own_pr_guard(number, "edit body")
        self.gh.call(["pr", "edit", str(number), "--body-file", "-"], input_text=body)

    def label_own_pr(
        self,
        number: int,
        *,
        add: list[str] | None = None,
        remove: list[str] | None = None,
    ) -> None:
        self._assert_writable("label own PR")
        self._own_pr_guard(number, "label")
        for name in add or []:
            if name not in FOREMAN_LABELS:
                raise ForemanError(
                    f"write contract: label '{name}' outside the foreman namespace"
                )
        args = ["pr", "edit", str(number)]
        for name in add or []:
            args += ["--add-label", name]
        for name in remove or []:
            args += ["--remove-label", name]
        if len(args) > 3:
            self.gh.call(args)

    def ready_own_pr(self, number: int) -> None:
        """Promote foreman's own draft PR to ready for review.

        The one-way door in the lifecycle: it notifies CODEOWNERS and requested
        reviewers, and `--undo` cannot unsend that. Callers must have satisfied
        the full readiness gate (shepherd.py) on an unchanged head first; this
        method only enforces the write contract, not the gate.
        """
        self._assert_writable("promote own PR to ready for review")
        self._own_pr_guard(number, "mark ready for review")
        self.gh.call(["pr", "ready", str(number)])

    def comment_own_pr(self, number: int, body: str) -> None:
        self._assert_writable("comment on own PR")
        self._own_pr_guard(number, "comment")
        self.gh.call(
            ["pr", "comment", str(number), "--body-file", "-"], input_text=body
        )

    def upsert_status_comment(self, issue_number: int, body: str) -> None:
        """Create or edit-in-place the single foreman status comment per unit."""
        self._assert_writable("upsert status comment")
        if STATUS_MARKER not in body:
            raise ForemanError("status comment body must carry the foreman marker")
        me = self.viewer()
        for comment in self.issue_comments(issue_number):
            author = (comment.get("user") or {}).get("login", "")
            # Only ever edit a comment foreman itself authored AND marked.
            if STATUS_MARKER in (comment.get("body") or "") and author == me:
                self.gh.call(
                    [
                        "api",
                        "--method",
                        "PATCH",
                        f"repos/{self.repo_slug()}/issues/comments/{comment['id']}",
                        "-f",
                        "body=@-",
                    ],
                    input_text=body,
                )
                return
        self.gh.call(
            [
                "api",
                "--method",
                "POST",
                f"repos/{self.repo_slug()}/issues/{issue_number}/comments",
                "-f",
                "body=@-",
            ],
            input_text=body,
        )

    def post_preflight_correction(
        self, issue_number: int, body: str, *, human_approved: bool
    ) -> None:
        """The ONLY general issue-comment write — gated on explicit human approval."""
        if not human_approved:
            raise ForemanError(
                "write contract: preflight corrections require human approval"
            )
        self._assert_writable("post approved preflight correction")
        self.gh.call(
            [
                "api",
                "--method",
                "POST",
                f"repos/{self.repo_slug()}/issues/{issue_number}/comments",
                "-f",
                "body=@-",
            ],
            input_text=body,
        )

    def resolve_review_thread(self, thread_id: str) -> None:
        self._assert_writable("resolve dispositioned review thread")
        self.gh.json(
            [
                "api",
                "graphql",
                "-f",
                f"query={RESOLVE_THREAD_MUTATION}",
                "-F",
                f"threadId={thread_id}",
            ]
        )
