"""Shared pytest fixtures.

Tests are split by marker:
- @pytest.mark.unit — pure Python, no Lightroom connection required
- @pytest.mark.integration — requires Lightroom Classic running with the
  Python Bridge plugin started. Skipped in CI.

Run unit tests only:
    pytest -m unit

Run everything including integration:
    pytest
"""

import sys
from pathlib import Path

# Make the project importable without needing `pip install -e .`
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
