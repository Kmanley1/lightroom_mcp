"""Smoke tests — verify the package imports and basic structure exists.

These run without a Lightroom connection. Their job is to fail fast if
the package is broken at the import level (typo, missing dependency,
syntax error). They are NOT a substitute for integration tests.
"""

import pytest


@pytest.mark.unit
def test_mcp_server_imports():
    """The main FastMCP composition server must be importable."""
    from mcp_server import main  # noqa: F401


@pytest.mark.unit
def test_catalog_server_imports():
    """The catalog tool server must be importable."""
    from mcp_server.servers import catalog  # noqa: F401


@pytest.mark.unit
def test_lightroom_sdk_imports():
    """The SDK client must be importable."""
    from lightroom_sdk import client  # noqa: F401


@pytest.mark.unit
def test_smart_collection_tools_defined():
    """Phase 2 smart-collection MCP tools must be defined in catalog.py.

    FastMCP registers tools via nested decorated functions inside the
    server class, so they aren't reachable as module attributes. This
    is a static-source check — adequate for a smoke test.
    """
    import inspect
    from mcp_server.servers import catalog

    source = inspect.getsource(catalog)
    expected = [
        "catalog_create_smart_collection",
        "catalog_get_smart_collection_criteria",
        "catalog_update_smart_collection",
        "catalog_delete_smart_collection",
    ]
    missing = [name for name in expected if f"def {name}" not in source]
    assert not missing, f"missing smart-collection tool definitions: {missing}"
