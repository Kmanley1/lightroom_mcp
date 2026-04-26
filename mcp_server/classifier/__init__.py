"""Source-taxonomy classifier for Phase 3.

The stamper (Lua side) is dumb about classifier internals — it receives
classifications and applies them. Adding a new classifier (v2 ML, etc.)
means dropping in a new module that conforms to the same shape:
    classify_batch(candidates: list[dict]) -> list[Classification]
"""
from .source_classifier import (
    CLASSIFIER_VERSION,
    ALL_SOURCE_KEYWORDS,
    Classification,
    CandidatePhoto,
    classify_batch,
    classify_one,
)

__all__ = [
    "CLASSIFIER_VERSION",
    "ALL_SOURCE_KEYWORDS",
    "Classification",
    "CandidatePhoto",
    "classify_batch",
    "classify_one",
]
