"""Watch-mode plumbing that must not regress: interval parsing."""

from __future__ import annotations

import unittest

from foreman.util import ForemanError
from foreman.watch import parse_interval


class ParseInterval(unittest.TestCase):
    def test_units(self):
        self.assertEqual(parse_interval("300"), 300)
        self.assertEqual(parse_interval("300s"), 300)
        self.assertEqual(parse_interval("5m"), 300)
        self.assertEqual(parse_interval("1h"), 3600)

    def test_rejects_garbage(self):
        for bad in ("", "5 minutes", "m5", "-5m"):
            with self.assertRaises(ForemanError):
                parse_interval(bad)

    def test_rejects_non_positive(self):
        # 0 would turn the watch loop into a tight spin.
        for bad in ("0", "0s", "0m", "0h"):
            with self.assertRaises(ForemanError):
                parse_interval(bad)


if __name__ == "__main__":
    unittest.main()
