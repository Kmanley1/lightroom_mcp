import asyncio
import json
import uuid
import logging
from pathlib import Path
from typing import Dict, Any, Optional, Tuple
from asyncio import StreamReader, StreamWriter
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading

logger = logging.getLogger(__name__)

CALLBACK_PORT = 54400

class SocketBridge:
    """Manages connection to Lightroom plugin.

    Commands: sent via TCP socket (LrSocket receive mode)
    Responses: received via HTTP POST from LR (LrHttp.post callback)
    """

    def __init__(self, host: str = 'localhost', port_file: str = None):
        self.host = host
        if port_file is None:
            port_file = str(Path.home() / 'lightroom_ports.txt')
        self.port_file = Path(port_file)
        self._send_writer: Optional[StreamWriter] = None
        self._receive_reader: Optional[StreamReader] = None
        self._pending_requests: Dict[str, asyncio.Future] = {}
        self._receive_task: Optional[asyncio.Task] = None
        self._http_server: Optional[HTTPServer] = None
        self._http_thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._connected = False

    async def connect(self, retry_attempts: int = 5, retry_delay: float = 2.0) -> None:
        """Establish connection with exponential backoff and port file monitoring"""
        port_file_notified = False
        
        for attempt in range(retry_attempts):
            try:
                ports = await self._read_ports()
                if not ports:
                    if not port_file_notified:
                        logger.info(f"Waiting for Lightroom plugin to start...")
                        logger.info(f"Port file not found at {self.port_file}")
                        logger.info("Please ensure:")
                        logger.info("  1. Lightroom Classic is running")
                        logger.info("  2. lightroom-python-bridge.lrdevplugin is installed and active")
                        logger.info("  3. Plugin has started successfully")
                        port_file_notified = True
                    
                    # Wait for port file to appear with polling
                    await self._wait_for_port_file(timeout=retry_delay * (2 ** attempt))
                    ports = await self._read_ports()
                    
                    if not ports:
                        from .exceptions import ConnectionError as LRConnectionError
                        raise LRConnectionError("Port file still not available")

                # Single-socket mode: both ports are the same
                port = ports[0]
                logger.info(f"Found Lightroom bridge port: {port}")

                # Start HTTP callback server for receiving responses
                self._loop = asyncio.get_event_loop()
                self._start_http_server()
                logger.info(f"HTTP callback server on port {CALLBACK_PORT}")

                # Connect to LR's receive socket (for sending commands)
                _, self._send_writer = await asyncio.open_connection(
                    self.host, port
                )
                logger.info(f"Connected to bridge port {port}")

                # Wait for LR to process connection
                await asyncio.sleep(0.5)

                self._connected = True
                logger.info("Connected to Lightroom bridge successfully!")
                return

            except Exception as e:
                logger.warning(f"Connection attempt {attempt + 1}/{retry_attempts} failed: {e}")
                # Clean up partial connection before retry
                if self._send_writer:
                    try:
                        self._send_writer.close()
                        await self._send_writer.wait_closed()
                    except Exception:
                        pass
                    self._send_writer = None
                self._receive_reader = None
                if attempt < retry_attempts - 1:
                    delay = retry_delay * (2 ** attempt)
                    logger.info(f"Retrying in {delay:.1f} seconds...")
                    await asyncio.sleep(delay)
                else:
                    from .exceptions import ConnectionError as LRConnectionError
                    error_msg = (
                        f"Failed to connect to Lightroom after {retry_attempts} attempts. "
                        f"Please ensure Lightroom Classic is running with the plugin active."
                    )
                    raise LRConnectionError(error_msg)

    async def _wait_for_port_file(self, timeout: float = 10.0, poll_interval: float = 0.5) -> None:
        """Wait for port file to appear with polling"""
        start_time = asyncio.get_event_loop().time()
        
        while (asyncio.get_event_loop().time() - start_time) < timeout:
            if self.port_file.exists():
                logger.info(f"Port file appeared at {self.port_file}")
                return
            await asyncio.sleep(poll_interval)
        
        logger.warning(f"Port file did not appear within {timeout:.1f} seconds")

    async def _read_ports(self) -> Optional[Tuple[int, int]]:
        """Read port numbers from Lightroom's port file"""
        if not self.port_file.exists():
            return None

        try:
            content = self.port_file.read_text().strip()
            ports = content.split(',')
            return int(ports[0]), int(ports[1])
        except Exception as e:
            logger.error(f"Failed to read port file: {e}")
            return None

    def _start_http_server(self):
        """Start HTTP server to receive responses from LR via LrHttp.post"""
        bridge = self

        class CallbackHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                content_length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(content_length)
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'ok')

                # Dispatch response to the asyncio event loop (thread-safe)
                try:
                    raw = body.decode('utf-8')
                    # Write to debug log (readable by Claude)
                    with open(str(Path.home() / 'lightroom_python_debug.log'), 'a') as dbg:
                        dbg.write(f"HTTP RECV ({len(raw)} bytes): {raw[:300]}\n")
                    message = json.loads(raw)
                    bridge._dispatch_message(message)
                except json.JSONDecodeError as e:
                    with open(str(Path.home() / 'lightroom_python_debug.log'), 'a') as dbg:
                        dbg.write(f"JSON ERROR: {e}\nRAW: {body[:200]}\n")
                except Exception as e:
                    with open(str(Path.home() / 'lightroom_python_debug.log'), 'a') as dbg:
                        dbg.write(f"DISPATCH ERROR: {e}\n")

            def log_message(self, format, *args):
                pass  # Suppress HTTP server logs

        self._http_server = HTTPServer(('localhost', CALLBACK_PORT), CallbackHandler)
        self._http_thread = threading.Thread(
            target=self._http_server.serve_forever,
            daemon=True
        )
        self._http_thread.start()

    def _dispatch_message(self, message: Dict[str, Any]) -> None:
        """Thread-safe dispatch of messages from HTTP callback to asyncio futures.
        Called from the HTTP server thread — uses call_soon_threadsafe."""

        # Handle events (just log, no future to resolve)
        if 'event' in message:
            logger.info(f"Event received: {message['event']}")
            return

        # Handle responses — match by request ID and resolve the future
        request_id = message.get('id')
        logger.info(f"HTTP callback received id={request_id}, pending={list(self._pending_requests.keys())}")

        if request_id and request_id in self._pending_requests:
            future = self._pending_requests.pop(request_id)
            if not future.cancelled():
                logger.info(f"Resolving future for {request_id}")
                try:
                    self._loop.call_soon_threadsafe(future.set_result, message)
                    logger.info(f"call_soon_threadsafe succeeded for {request_id}")
                except Exception as e:
                    logger.error(f"call_soon_threadsafe failed: {e}")
            else:
                logger.warning(f"Future already cancelled for {request_id}")
        else:
            logger.warning(f"No pending request for id: {request_id}")

    async def send_command(
        self,
        command: str,
        params: Optional[Dict[str, Any]] = None,
        timeout: float = 120.0
    ) -> Dict[str, Any]:
        """Send command and await response"""
        if not self._connected:
            from .exceptions import ConnectionError as LRConnectionError
            raise LRConnectionError("Not connected to Lightroom")

        request_id = str(uuid.uuid4())
        request = {
            'id': request_id,
            'command': command,
            'params': params or {}
        }

        # Capture the running event loop (may differ from connect-time loop)
        self._loop = asyncio.get_running_loop()

        # Create future for response
        future = self._loop.create_future()
        self._pending_requests[request_id] = future

        try:
            # Send request
            request_json = json.dumps(request) + '\n'
            self._send_writer.write(request_json.encode('utf-8'))
            await self._send_writer.drain()

            # Wait for response
            response = await asyncio.wait_for(future, timeout=timeout)
            return response

        except asyncio.TimeoutError:
            self._pending_requests.pop(request_id, None)
            from .exceptions import TimeoutError as LRTimeoutError
            raise LRTimeoutError(f"Command '{command}' timed out after {timeout}s")
        except Exception as e:
            self._pending_requests.pop(request_id, None)
            raise

    async def disconnect(self) -> None:
        """Close connections gracefully"""
        self._connected = False

        if self._http_server:
            self._http_server.shutdown()
            self._http_server = None

        if self._send_writer:
            self._send_writer.close()
            try:
                await self._send_writer.wait_closed()
            except Exception:
                pass

        logger.info("Disconnected from Lightroom bridge")