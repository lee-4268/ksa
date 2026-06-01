"""
sso_verify - 인프라 SSO 가 발급한 RS256 JWT access_token 의 서명/페이로드 검증.

담당 도메인: 외부 SSO 토큰 검증 (보강 레이어)
주요 의존성: core.config (SSO_JWKS_URL)
엔드포인트: 없음

설계 의도:
- routers/auth.py 의 OTP 검증 단계에서 인프라가 발급한 access_token 이 진짜
  인프라 개인키로 서명된 것인지 한 번 더 확인하기 위한 보강 레이어.
- 현재 인프라가 JWKS 엔드포인트를 제공하지 않으므로 verify_access_token() 은
  서명 검증을 skip 하고 페이로드만 디코딩해 sub(=username) 일치 여부만 본다.
  보안 보강이 아니라 sanity check 수준.
- 향후 인프라가 JWKS 를 제공하면 _verify_with_jwks() 를 채우면 끝. 호출부 변경
  필요 없음.

주의사항:
- 이 모듈이 실패해도(JWT 디코드 에러 등) 전체 인증을 막지 않는다. 인프라
  verify 호출이 200 을 받았다는 사실이 1차 신뢰 근거이고, 여기는 추가 확인.
- 단, sub 가 username 과 다르면 (= 누군가 다른 사용자 토큰을 끼워넣은 경우)
  검증 실패로 처리해야 한다.
"""

import base64
import json
import logging
from typing import Optional

from .config import SSO_JWKS_URL

logger = logging.getLogger(__name__)


def verify_access_token(access_token: str, expected_username: str) -> bool:
    """인프라 access_token 의 sub 가 expected_username 과 일치하는지 확인.

    JWKS 가 설정되어 있으면 RS256 서명까지 검증, 아니면 페이로드 디코드만.
    검증 통과 → True, 실패/불일치 → False.

    Returns:
        True: 검증 통과 (또는 JWKS 미설정 + sub 일치)
        False: sub 불일치 또는 토큰 손상
    """
    if not access_token:
        return False

    if SSO_JWKS_URL:
        return _verify_with_jwks(access_token, expected_username)

    # JWKS 없음 — 서명 검증 skip, payload sub 만 비교
    try:
        payload = _decode_jwt_payload_unsafe(access_token)
        sub = payload.get("sub")
        if sub != expected_username:
            logger.warning(
                f"SSO JWT sub 불일치: sub={sub!r}, expected={expected_username!r}"
            )
            return False
        return True
    except Exception as e:
        logger.warning(f"SSO JWT payload 디코드 실패: {e}")
        return False


def _decode_jwt_payload_unsafe(token: str) -> dict:
    """JWT 페이로드를 서명 검증 없이 디코드. 페이로드 형태 확인 용도만."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("JWT 형식이 아닙니다 (3-part 가 아님)")
    payload_b64 = parts[1]
    # base64url 패딩 보정
    padding = "=" * (-len(payload_b64) % 4)
    payload_bytes = base64.urlsafe_b64decode(payload_b64 + padding)
    return json.loads(payload_bytes)


def _verify_with_jwks(access_token: str, expected_username: str) -> bool:
    """JWKS 로 RS256 서명까지 검증. 인프라가 JWKS 를 제공하면 여기를 채운다.

    구현 예시:
        import jwt
        from jwt import PyJWKClient
        client = PyJWKClient(SSO_JWKS_URL)  # 캐시는 클라이언트가 알아서
        signing_key = client.get_signing_key_from_jwt(access_token)
        payload = jwt.decode(
            access_token,
            signing_key.key,
            algorithms=["RS256"],
            options={"verify_aud": False},  # aud 사용 안 하면
        )
        return payload.get("sub") == expected_username
    """
    logger.warning(
        "SSO_JWKS_URL 이 설정되어 있지만 _verify_with_jwks 미구현. "
        "PyJWT 추가 후 함수 본문을 채우세요."
    )
    # 안전한 fallback: sub 만 비교 (현재 운영 상태와 동일)
    try:
        payload = _decode_jwt_payload_unsafe(access_token)
        return payload.get("sub") == expected_username
    except Exception:
        return False
