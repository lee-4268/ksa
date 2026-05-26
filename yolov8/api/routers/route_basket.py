"""
route_basket - 경로 담기 엔드포인트

담당 도메인: 무선국 방문 경로 담기 관리
주요 의존성: core.auth, core.db, core.config
엔드포인트:
    GET    /route-basket
    POST   /route-basket
    PATCH  /route-basket/{entry_id}
    DELETE /route-basket/{entry_id}
"""

import asyncio
import logging
import uuid
from datetime import datetime
from decimal import Decimal

from boto3.dynamodb.conditions import Key
from fastapi import APIRouter, Request

from core.auth import _verify_auth
from core.config import DYNAMODB_TABLES
from core.db import get_dynamodb_resource

router = APIRouter(tags=["route_basket"])
logger = logging.getLogger(__name__)


@router.get("/route-basket")
async def get_route_baskets(request: Request):
    """사용자 경로 담기 목록 조회."""
    empno = await _verify_auth(request)
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    resp = await asyncio.to_thread(lambda: table.query(
        KeyConditionExpression=Key("user_id").eq(empno),
        ScanIndexForward=False,
    ))

    def _fix(item):
        stations = item.get("stations", [])
        return {**item, "stations": [
            {**s, "lat": float(s["lat"]), "lng": float(s["lng"])} for s in stations
        ]}

    return {"entries": [_fix(i) for i in resp.get("Items", [])]}


@router.post("/route-basket")
async def save_route_basket(request: Request):
    """경로 담기 저장."""
    empno = await _verify_auth(request)
    body = await request.json()
    entry_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()
    stations_raw = body.get("stations", [])
    stations = [
        {
            "id": s.get("id", ""),
            "name": s.get("name", ""),
            "lat": Decimal(str(s.get("lat", 0))),
            "lng": Decimal(str(s.get("lng", 0))),
        }
        for s in stations_raw
    ]
    item = {
        "user_id": empno,
        "entry_id": entry_id,
        "title": body.get("title", ""),
        "week_label": body.get("week_label", ""),
        "jo_label": body.get("jo_label", ""),
        "stations": stations,
        "created_at": now,
    }
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    await asyncio.to_thread(lambda: table.put_item(Item=item))
    item_resp = {**item, "stations": [
        {**s, "lat": float(s["lat"]), "lng": float(s["lng"])} for s in stations
    ]}
    return {"entry": item_resp}


@router.patch("/route-basket/{entry_id}")
async def update_route_basket(request: Request, entry_id: str):
    """경로 담기 국소 순서 수정."""
    empno = await _verify_auth(request)
    body = await request.json()
    stations_raw = body.get("stations", [])
    stations = [
        {
            "id": s.get("id", ""),
            "name": s.get("name", ""),
            "lat": Decimal(str(s.get("lat", 0))),
            "lng": Decimal(str(s.get("lng", 0))),
        }
        for s in stations_raw
    ]
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    await asyncio.to_thread(lambda: table.update_item(
        Key={"user_id": empno, "entry_id": entry_id},
        UpdateExpression="SET stations = :s",
        ExpressionAttributeValues={":s": stations},
    ))
    return {"success": True}


@router.delete("/route-basket/{entry_id}")
async def delete_route_basket(request: Request, entry_id: str):
    """경로 담기 삭제."""
    empno = await _verify_auth(request)
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    await asyncio.to_thread(lambda: table.delete_item(
        Key={"user_id": empno, "entry_id": entry_id}
    ))
    return {"success": True}
