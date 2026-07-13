"""Human-queue rendering that must not regress: merge-order numbering."""

from __future__ import annotations

import unittest

from foreman.report import human_queue


class MergeOrderNumbering(unittest.TestCase):
    def test_positions_are_sequential(self):
        out = human_queue(
            merge_order=[(10, "u10"), (12, "u12"), (11, "u11")],
            human_tasks={},
            blocked={},
            environmental={},
        )
        self.assertIn("1. #10", out)
        self.assertIn("2. #12", out)
        self.assertIn("3. #11", out)

    def test_empty_queue_says_so(self):
        out = human_queue(merge_order=[], human_tasks={}, blocked={}, environmental={})
        self.assertIn("empty", out)


if __name__ == "__main__":
    unittest.main()
