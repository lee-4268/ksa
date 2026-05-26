"""
db - DynamoDB/SQLite 연결 싱글턴 함수

담당 도메인: DB 클라이언트 생성 및 재사용
주요 의존성: core.config
엔드포인트: 없음

주의사항:
- boto3 client/resource는 thread-safe → 모듈 수준 싱글턴 안전
- max_pool_connections=25로 EC2 커넥션 풀 재사용
"""

import boto3
from botocore.config import Config as _BotoConfig
from .config import S3_REGION

# boto3 연결 풀 설정
_boto_config = _BotoConfig(max_pool_connections=25)

# 모듈 수준 싱글턴 (요청마다 재생성 금지 — EC2 메모리·연결 절약)
_s3_client = boto3.client('s3', region_name=S3_REGION, config=_boto_config)

# xlsx 대용량 다운로드 전용 클라이언트 (read_timeout 600초, hang 방지)
_s3_client_xlsx = boto3.client('s3', region_name=S3_REGION, config=_BotoConfig(
    max_pool_connections=2, connect_timeout=10, read_timeout=600,
    retries={'max_attempts': 1},
))

_dynamodb_resource = boto3.resource('dynamodb', region_name=S3_REGION, config=_boto_config)
_dynamodb_client = boto3.client('dynamodb', region_name=S3_REGION, config=_boto_config)


def get_s3_client():
    """S3 클라이언트 반환 (싱글턴)."""
    return _s3_client


def get_s3_client_xlsx():
    """xlsx 대용량 다운로드 전용 S3 클라이언트 반환."""
    return _s3_client_xlsx


def get_dynamodb_resource():
    """DynamoDB resource 반환 (싱글턴)."""
    return _dynamodb_resource


def get_dynamodb_client():
    """DynamoDB client 반환 (싱글턴)."""
    return _dynamodb_client
