"""
System server module for connection management
"""
from typing import Dict, Any
from datetime import datetime
from mcp_server.shared.base import LightroomServerModule
from mcp_server.shared.resilient_client import resilient_client_manager
from lightroom_sdk import LightroomClient
import logging

logger = logging.getLogger(__name__)

class SystemServer(LightroomServerModule):
    """System and connection management tools"""

    @property
    def name(self) -> str:
        return "Lightroom System Tools"

    @property
    def prefix(self) -> str:
        return "system"

    def _setup_tools(self):
        """Register system tools"""

        @self.server.tool
        async def system_ping() -> Dict[str, Any]:
            """
            Test connectivity to Lightroom.

            Returns:
                Connection status and response time
            """
            client = await resilient_client_manager.get_client()

            start_time = datetime.now()
            result = await client.ping()
            duration_ms = (datetime.now() - start_time).total_seconds() * 1000

            return {
                "status": "connected",
                "message": result.get("message", "pong"),
                "response_time_ms": round(duration_ms, 2)
            }

        @self.server.tool
        async def system_status() -> Dict[str, Any]:
            """
            Get detailed status of the Lightroom bridge.

            Returns:
                Bridge statistics and connection information
            """
            status = await self.execute_command("status")

            return {
                "connection": "active",
                "uptime_seconds": status.get("uptime", 0),
                "total_requests": status.get("requestCount", 0),
                "total_errors": status.get("errorCount", 0),
                "lightroom_version": status.get("lightroomVersion", "Unknown"),
                "plugin_version": status.get("pluginVersion", "2.0.0"),
                "available_modules": ["system", "catalog", "develop", "preview"]
            }

        @self.server.tool
        async def system_reconnect() -> Dict[str, str]:
            """
            Reconnect to the Lightroom bridge.

            Useful if the connection is lost or Lightroom was restarted.

            Returns:
                Reconnection status
            """
            # Disconnect and reconnect
            await resilient_client_manager.disconnect()
            await resilient_client_manager.connect()

            return {
                "status": "reconnected",
                "message": "Successfully reconnected to Lightroom bridge"
            }

        @self.server.tool
        async def system_check_photo_selected() -> Dict[str, Any]:
            """
            Check if a photo is currently selected in Lightroom.

            Returns:
                Selection status and count
            """
            try:
                client = await resilient_client_manager.get_client()
                result = await client.execute_command("catalog.getSelectedPhotos")
                photo_count = result.get("count", 0)

                return {
                    "has_selection": photo_count > 0,
                    "selected_count": photo_count,
                    "selected_photos": result.get("photos", [])[:5]  # First 5 photos
                }
            except Exception as e:
                logger.error(f"Failed to check selection: {e}")
                return {
                    "has_selection": False,
                    "selected_count": 0,
                    "error": str(e)
                }

# Create server instance
system_server = SystemServer()