"""
categories - 카테고리 CRUD 엔드포인트

담당 도메인: 분류 카테고리 관리
주요 의존성: core.auth, core.db, core.config, core.utils
엔드포인트:
    POST   /categories
    GET    /categories
    GET    /categories/{category_id}
    PUT    /categories/{category_id}
    DELETE /categories/{category_id}
"""

import asyncio
import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, HTTPException, Query, Request
from botocore.exceptions import ClientError

from core.auth import _verify_auth, _require_owner_or_admin, _check_object_owner_or_admin
from core.config import DYNAMODB_TABLES
from core.db import get_dynamodb_resource
from core.utils import decimal_to_native
from schemas.models import CategoryCreate

router = APIRouter(tags=["categories"])
logger = logging.getLogger(__name__)


@router.post("/categories")
async def create_category(category: CategoryCreate, request: Request):
    """카테고리 생성 — 본인 owner 또는 admin."""
    await _require_owner_or_admin(request, category.owner)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])
        now = datetime.now(timezone.utc).isoformat()
        item = {
            "id": str(uuid.uuid4()),
            "name": category.name,
            "owner": category.owner,
            "createdAt": now,
            "updatedAt": now,
        }
        if category.originalExcelKey:
            item["originalExcelKey"] = category.originalExcelKey
        table.put_item(Item=item)
        return {"success": True, "category": item}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/categories")
async def list_categories(
    owner: str = Query(..., description="소유자 사번"),
    request: Request = None,
):
    """카테고리 목록 조회 — 본인 owner 또는 admin."""
    await _require_owner_or_admin(request, owner)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])
        response = table.scan(
            FilterExpression="#owner = :owner",
            ExpressionAttributeNames={"#owner": "owner"},
            ExpressionAttributeValues={":owner": owner},
        )
        items = response.get("Items", [])
        while "LastEvaluatedKey" in response:
            response = table.scan(
                FilterExpression="#owner = :owner",
                ExpressionAttributeNames={"#owner": "owner"},
                ExpressionAttributeValues={":owner": owner},
                ExclusiveStartKey=response["LastEvaluatedKey"],
            )
            items.extend(response.get("Items", []))
        return {"success": True, "categories": decimal_to_native(items), "count": len(items)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/categories/{category_id}")
async def get_category(category_id: str, request: Request = None):
    """카테고리 단일 조회 — 객체 owner 또는 admin."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])
        response = table.get_item(Key={"id": category_id})
        item = response.get("Item")
        if not item:
            await _verify_auth(request)
            raise HTTPException(status_code=404, detail="Category not found")
        await _check_object_owner_or_admin(request, "카테고리", str(item.get("owner") or ""))
        return {"success": True, "category": decimal_to_native(item)}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.put("/categories/{category_id}")
async def update_category(
    category_id: str,
    request: Request,
    name: str = None,
    originalExcelKey: str = None,
):
    """카테고리 업데이트 — 객체 owner 또는 admin."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])
        existing = table.get_item(Key={"id": category_id}).get("Item")
        if not existing:
            await _verify_auth(request)
            raise HTTPException(status_code=404, detail="Category not found")
        await _check_object_owner_or_admin(request, "카테고리", str(existing.get("owner") or ""))

        update_expr = "SET updatedAt = :now"
        expr_values = {":now": datetime.now(timezone.utc).isoformat()}
        if name:
            update_expr += ", #n = :name"
            expr_values[":name"] = name
        if originalExcelKey:
            update_expr += ", originalExcelKey = :key"
            expr_values[":key"] = originalExcelKey

        update_kwargs = {
            "Key": {"id": category_id},
            "UpdateExpression": update_expr,
            "ExpressionAttributeValues": expr_values,
            "ReturnValues": "ALL_NEW",
        }
        if name:
            update_kwargs["ExpressionAttributeNames"] = {"#n": "name"}
        response = table.update_item(**update_kwargs)
        return {"success": True, "category": decimal_to_native(response.get("Attributes"))}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.delete("/categories/{category_id}")
async def delete_category(category_id: str, request: Request = None):
    """카테고리 삭제 — 객체 owner 또는 admin."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])
        existing = table.get_item(Key={"id": category_id}).get("Item")
        if not existing:
            await _verify_auth(request)
            raise HTTPException(status_code=404, detail="Category not found")
        await _check_object_owner_or_admin(request, "카테고리", str(existing.get("owner") or ""))
        table.delete_item(Key={"id": category_id})
        return {"success": True, "message": "Category deleted"}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
