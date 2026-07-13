"""Entry point: PYTHONPATH=scripts python3 -m foreman <command> [flags]."""

import sys

from foreman.cli import main

if __name__ == "__main__":
    sys.exit(main())
