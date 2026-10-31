"""Iris: a local web_extract provider for Hermes Agent."""
from __future__ import annotations

from .provider import IrisWebProvider


def register(ctx) -> None:
    ctx.register_web_search_provider(IrisWebProvider())
