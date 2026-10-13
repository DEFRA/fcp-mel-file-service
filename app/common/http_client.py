from logging import getLogger

import httpx2

from app.common.tracing import ctx_trace_id
from app.config import config

logger = getLogger(__name__)


async def async_hook_request_tracing(request):
    trace_id = ctx_trace_id.get(None)
    if trace_id:
        request.headers[config.tracing_header] = trace_id


def hook_request_tracing(request):
    trace_id = ctx_trace_id.get(None)
    if trace_id:
        request.headers[config.tracing_header] = trace_id


def create_async_client(request_timeout: int = 30) -> httpx2.AsyncClient:
    """
    Create an async HTTP client with configurable timeout.

    Args:
        request_timeout: Request timeout in seconds

    Returns:
        Configured httpx2.AsyncClient instance
    """
    client_kwargs = {
        "timeout": request_timeout,
        "event_hooks": {"request": [async_hook_request_tracing]},
    }

    return httpx2.AsyncClient(**client_kwargs)


def create_client(request_timeout: int = 30) -> httpx2.Client:
    """
    Create a sync HTTP client with configurable timeout.

    Args:
        request_timeout: Request timeout in seconds

    Returns:
        Configured httpx2.Client instance
    """
    client_kwargs = {
        "timeout": request_timeout,
        "event_hooks": {"request": [hook_request_tracing]},
    }

    return httpx2.Client(**client_kwargs)
