"""
stations - 무선국 CRUD 엔드포인트

담당 도메인: 무선국 관리
주요 의존성: core.auth, core.db, core.config, core.utils
엔드포인트:
    POST   /stations
    GET    /stations
    GET    /stations/{station_id}
    PUT    /stations/{station_id}
    DELETE /stations/{station_id}
"""

import asyncio
import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal

from fastapi import APIRouter, HTTPException, Query, Request
from botocore.exceptions import ClientError

from core.auth import _verify_auth, _require_owner_or_admin, _check_object_owner_or_admin
from core.config import DYNAMODB_TABLES
from core.db import get_dynamodb_resource
from core.utils import decimal_to_native
from schemas.models import StationCreate, StationUpdate

router = APIRouter(tags=["stations"])
logger = logging.getLogger(__name__)


@router.post("/stations")
async def create_station(station: StationCreate, request: Request):
    """무선국 생성 — 본인 owner 또는 admin."""
    await _require_owner_or_admin(request, station.owner)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])
        now = datetime.now(timezone.utc).isoformat()
        item = {
            "id": str(uuid.uuid4()),
            "categoryId": station.categoryId,
            "owner": station.owner,
            "stationName": station.stationName,
            "address": station.address,
            "isInspected": station.isInspected,
            "createdAt": now,
            "updatedAt": now,
        }
        optional_fields = [
            "licenseNumber", "latitude", "longitude", "callSign", "gain",
            "antennaCount", "remarks", "typeApprovalNumber", "frequency",
            "stationType", "stationOwner", "installationType", "inspectionStatus",
            "inspectionDate", "memo", "photoKeys",
        ]
        for field in optional_fields:
            value = getattr(station, field)
            if value is not None:
                if isinstance(value, float):
                    item[field] = Decimal(str(value))
                else:
                    item[field] = value
        table.put_item(Item=item)
        return {"success": True, "station": decimal_to_native(item)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/stations")
async def list_stations(
    owner: str = Query(..., description="소유자 사번"),
    categoryId: str = Query(None, description="카테고리 ID (선택)"),
    request: Request = None,
):
    """무선국 목록 조회 — 본인 owner 또는 admin."""
    await _require_owner_or_admin(request, owner)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])
        filter_expr = "#owner = :owner"
        expr_names = {"#owner": "owner"}
        expr_values = {":owner": owner}
        if categoryId:
            filter_expr += " AND categoryId = :catId"
            expr_values[":catId"] = categoryId
        response = table.scan(
            FilterExpression=filter_expr,
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values,
        )
        items = response.get("Items", [])
        while "LastEvaluatedKey" in response:
            response = table.scan(
                FilterExpression=filter_expr,
                ExpressionAttributeNames=expr_names,
                ExpressionAttributeValues=expr_values,
                ExclusiveStartKey=response["LastEvaluatedKey"],
            )
            items.extend(response.get("Items", []))
        return {"success": True, "stations": decimal_to_native(items), "count": len(items)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/stations/{station_id}")
async def get_station(station_id: str, request: Request = None):
    """무선국 단일 조회 — 객체 owner 또는 admin."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])
        response = table.get_item(Key={"id": station_id})
        item = response.get("Item")
        if not item:
            await _verify_auth(request)
            raise HTTPException(status_code=404, detail="Station not found")
        await _check_object_owner_or_admin(request, "스테이션", str(item.get("owner") or ""))
        return {"success": True, "station": decimal_to_native(item)}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.put("/stations/{station_id}")
async def update_station(station_id: str, station: StationUpdate, request: Request = None):
    """무선국 업데이트 — 객체 owner 또는 admin."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])
        existing = table.get_item(Key={"id": station_id}).get("Item")
        if not existing:
            await _verify_auth(request)
            raise HTTPException(status_code=404, detail="Station not found")
        await _check_object_owner_or_admin(request, "스테이션", str(existing.get("owner") or ""))

        update_expr = "SET updatedAt = :now"
        expr_values = {":now": datetime.now(timezone.utc).isoformat()}
        expr_names = {}
        reserved_words = {
            "name", "owner", "status", "address", "comment", "type",
            "key", "value", "data", "source", "role", "user", "size",
            "time", "date",
        }
        update_fields = station.dict(exclude_unset=True)
        for field, value in update_fields.items():
            if value is not None:
                if isinstance(value, float):
                    value = Decimal(str(value))
                if field.lower() in reserved_words:
                    alias = f"#{field}"
                    expr_names[alias] = field
                    update_expr += f", {alias} = :{field}"
                else:
                    update_expr += f", {field} = :{field}"
                expr_values[f":{field}"] = value

        update_kwargs = {
            "Key": {"id": station_id},
            "UpdateExpression": update_expr,
            "ExpressionAttributeValues": expr_values,
            "ReturnValues": "ALL_NEW",
        }
        if expr_names:
            update_kwargs["ExpressionAttributeNames"] = expr_names
        response = table.update_item(**update_kwargs)
        return {"success": True, "station": decimal_to_native(response.get("Attributes"))}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.delete("/stations/{station_id}")
async def delete_station(station_id: str, request: Request = None):
    """무선국 삭제 — 객체 owner 또는 admin."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])
        existing = table.get_item(Key={"id": station_id}).get("Item")
        if not existing:
            await _verify_auth(request)
            raise HTTPException(status_code=404, detail="Station not found")
        await _check_object_owner_or_admin(request, "스테이션", str(existing.get("owner") or ""))
        table.delete_item(Key={"id": station_id})
        return {"success": True, "message": "Station deleted"}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
