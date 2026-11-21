"""GET /api/stats: latency percentiles, tokens and estimated cost of every Gemini call Core made
since start (see gemini.py). DELETE /api/stats resets the counters (handy before a bench run)."""

from fastapi import APIRouter, Response

import gemini

router = APIRouter()


@router.get("/api/stats")
async def api_stats():
    return gemini.snapshot()


@router.delete("/api/stats")
async def api_stats_reset():
    gemini.reset_stats()
    return Response(status_code=204)
