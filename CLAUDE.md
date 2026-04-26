# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Model Context Protocol (MCP) server for Adobe Lightroom Classic. Enables AI agents to control Lightroom catalog operations, RAW photo development, preview generation, and histogram analysis.

**Architecture**: Three-tier system
```
[AI Agent/LLM] <--MCP--> [Python FastMCP Server] <--JSON/TCP--> [Lightroom Lua Plugin] <--> [Lightroom Classic]
```

## Running and Testing

**Start MCP Server**:
```bash
python -m mcp_server.main          # Run as module (recommended)
python mcp_server/main.py          # Direct execution
./venv/bin/python -m mcp_server.main  # With virtual environment
```

**Install Dependencies**:
```bash
pip install -r requirements.txt
```

**Run Tests**:
```bash
python -m pytest tests/                        # all tests
python -m pytest tests/ -m unit                # unit only (no Lightroom required)
python -m pytest tests/ -m integration         # integration (requires LR + bridge)
python -c "from mcp_server.main import main_server; print('Server loaded successfully')"
```

Tests live in `tests/` (per `pytest.ini`). Markers: `unit` (pure Python,
runs anywhere), `integration` (requires Lightroom Classic running with
the Python Bridge plugin started).

**Lightroom Plugin Setup**:
1. Plugin must be installed in Lightroom first (`File → Plug-in Manager → Add`)
2. Start bridge: `File → Plug-in Extras → Start Python Bridge`
3. Plugin logs: `~/Logs/Adobe/Lightroom/LrClassicLogs/LightroomPythonBridge.log` (Mac)

## Key Architecture Components

### MCP Layer (`mcp_server/`)
- **main.py**: FastMCP composition server that mounts all tool modules
- **servers/**: Modular FastMCP servers (system, catalog, develop/, preview)
  - **develop/**: 11 specialized modules for photo editing (basic_tools, tone_curves, color_tools, detail_tools, lens_tools, effects_tools, calibration_tools, parameter_management, helper_tools, plus main.py composition)
- **shared/resilient_client.py**: Auto-reconnection manager with timeout handling
- **middleware/error_handler.py**: Exception mapping from Lightroom SDK to MCP

### SDK Layer (`lightroom_sdk/`)
- **client.py**: Main LightroomClient class with command execution
- **socket_bridge.py**: TCP socket management (dual sockets required due to LrSocket limitations)
- **protocol.py**: JSON request/response structures
- **exceptions.py**: Structured exception hierarchy with ERROR_CODE_MAP

### Lightroom Plugin (`lightroom-python-bridge.lrdevplugin/`)
- **CommandRouter.lua**: Dynamic command dispatcher (66+ registered handlers)
- **SimpleSocketBridge.lua**: Dual TCP socket manager (send + receive)
- **MessageProtocol.lua**: JSON encoding/decoding with error recovery
- **CatalogModule.lua** & **DevelopModule.lua**: Lightroom API wrappers
- **ErrorUtils.lua**: Parameter validation and error formatting

## Critical Lightroom Constraints

**Socket Communication**:
- Lightroom's LrSocket is unidirectional → requires dual sockets (one send, one receive)
- All messages must be strings → JSON serialized to strings
- Use `obj.method(arg)` NOT `obj:method(arg)` for socket method calls

**Lua Module Behavior**:
- Lua modules cached by Lightroom → restart Lightroom to reload plugin code changes
- Use global state `_G.LightroomPythonBridge` for shared objects between modules

**Catalog Access Patterns**:
- ALL catalog reads must wrap in `catalog:withReadAccessDo(function() ... end)`
- ALL catalog writes must wrap in `catalog:withWriteAccessDo(function() ... end)`
- Violating this causes silent failures or crashes

**Develop Module Requirements**:
- Most develop operations require photo selected AND Develop tab open in Lightroom
- Returns `NO_PHOTO_SELECTED` error with severity="error" if no photo selected
- Never auto-select photos to avoid unexpected UX

## Error Handling Flow

Python exceptions map to Lightroom error codes via `ERROR_CODE_MAP`:
- `NO_PHOTO_SELECTED` → `PhotoNotSelectedError`
- `INVALID_PARAM_VALUE` → `ParameterOutOfRangeError`
- `PHOTO_NOT_FOUND` → `PhotoNotFoundError`
- `CATALOG_ACCESS_FAILED` → `CatalogAccessError`
- `HANDLER_ERROR` → `HandlerError`

All Lightroom errors return:
```json
{
  "success": false,
  "error": {
    "code": "NO_PHOTO_SELECTED",
    "message": "Please select a photo",
    "severity": "error"
  }
}
```

## Performance Considerations

- **Batch operations**: 10-20x faster than individual calls (use `develop_set_parameters`)
- **Chunked transfer**: Automatic for large data >10MB (preview images)
- **Preview resizing**: PIL resizes images since Lightroom returns full resolution
- **Temperature/Tint**: Set individually (not in batch) for compatibility
- **Client delay**: 100ms delay in `client.py:58` after each command (prevents race conditions)

## Adding New MCP Tools

1. Create tool function in appropriate server module (`mcp_server/servers/`)
2. Use `@server.tool` decorator with clear docstring
3. Call `await resilient_client_manager.execute_command(command, params)`
4. Add corresponding Lua handler in `CommandRouter.lua` if needed
5. Update tool count in `main.py:list_capabilities()`

## Common Development Workflows

**Testing connection**:
```python
from lightroom_sdk.client import LightroomClient
client = LightroomClient()
await client.connect()
await client.ping()
```

**Debugging Lua plugin**:
1. Check logs: `~/Logs/Adobe/Lightroom/LrClassicLogs/LightroomPythonBridge.log`
2. Add `logger:info("message")` in Lua code
3. Restart Lightroom to reload plugin

**Adding develop parameter**:
1. Add to `DevelopModule.lua` parameter validation
2. Add MCP tool in `mcp_server/servers/develop/basic_tools.py` (or appropriate module)
3. Update parameter ranges in docstring