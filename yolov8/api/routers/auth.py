"""
auth - 인증/로그인/OTP/토큰 갱신 엔드포인트

담당 도메인: 사용자 인증
주요 의존성: core.auth, core.config
엔드포인트:
    POST /auth/login
    POST /auth/verify-otp
    POST /auth/resend-otp
    POST /auth/logout
    POST /auth/refresh
    POST /auth/dev-login
    GET  /auth/dev-login/status
"""

import asyncio
import logging
import time as _time_mod

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from core.auth import (
    _verify_auth, _generate_token, _blacklist_token,
    _get_user_role_info, _ensure_user_in_roles_sync, _update_last_login,
    _get_user_phone_sync, _send_otp_sync, _mask_phone,
    _is_valid_phone, _pre_auth_store, _sms_rate_store, _dev_users,
)
from core.config import (
    SSO_LOGIN_URL, DEV_LOGIN_ENABLED, IS_PROD, VALID_ROLES,
    AUTH_TOKEN_EXPIRY,
)
from core.utils import _check_rate_limit
from schemas.models import LoginRequest, OtpVerifyRequest, OtpResendRequest, DevLoginRequest

router = APIRouter(prefix="/auth", tags=["auth"])
logger = logging.getLogger(__name__)

# OTP 관련 상수 (core.auth에서 re-import)
from core.auth import (
    PRE_AUTH_EXPIRY, OTP_MAX_ATTEMPTS, SMS_RATE_MAX, SMS_RATE_WINDOW
)
import hmac as _hmac_mod
import secrets as _secrets_mod


@router.post("/login")
async def proxy_sso_login(req: LoginRequest, request: Request):
    """SKons SSO 로그인 프록시 + 2차 SMS OTP 발송."""
    _check_rate_limit(request, "login", 5, 60)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                SSO_LOGIN_URL,
                json={"username": req.username, "password": req.password},
                headers={"Content-Type": "application/json"},
            )
        sso_data = response.json()

        if response.status_code == 200 and sso_data.get("result") == "ok":
            # 사번 대문자 정규화
            username = req.username.upper()
            # 휴면계정 차단
            role_info = await asyncio.to_thread(_get_user_role_info, username)
            if role_info["is_dormant"]:
                return JSONResponse(
                    status_code=403,
                    content={"result": "fail", "message": "휴면 계정입니다. 관리자에게 문의하거나 이메일 인증을 진행해 주세요."},
                )
            await asyncio.to_thread(_ensure_user_in_roles_sync, username)

            # 2차 SMS OTP
            phone = await asyncio.to_thread(_get_user_phone_sync, username)
            if not _is_valid_phone(phone or ""):
                return JSONResponse(
                    status_code=403,
                    content={"result": "fail", "message": "등록된 휴대폰 번호가 없습니다. 관리자에게 문의하세요."},
                )
            # SMS 발송 횟수 제한
            now = _time_mod.time()
            rate_ts = [t for t in _sms_rate_store.get(username, []) if now - t < SMS_RATE_WINDOW]
            if len(rate_ts) >= SMS_RATE_MAX:
                return JSONResponse(
                    status_code=429,
                    content={"result": "fail", "message": f"SMS 발송 횟수를 초과했습니다. {SMS_RATE_WINDOW // 60}분 후 재시도하세요."},
                )
            rate_ts.append(now)
            _sms_rate_store[username] = rate_ts

            try:
                otp = await asyncio.to_thread(_send_otp_sync, phone, username)
            except Exception as e:
                logger.error(f"OTP SMS 발송 실패: {e}")
                return JSONResponse(
                    status_code=503,
                    content={"result": "fail", "message": "SMS 발송에 실패했습니다. 잠시 후 다시 시도하세요."},
                )

            pre_auth_token = _secrets_mod.token_urlsafe(32)
            _pre_auth_store[pre_auth_token] = {
                "empno": username, "otp": otp, "phone": phone,
                "expiry": now + PRE_AUTH_EXPIRY, "attempts": 0,
            }
            return JSONResponse(
                status_code=200,
                content={"result": "otp_required", "pre_auth_token": pre_auth_token,
                         "masked_phone": _mask_phone(phone), "expires_in": PRE_AUTH_EXPIRY},
            )

        return JSONResponse(status_code=response.status_code, content=sso_data)
    except httpx.TimeoutException:
        return JSONResponse(
            status_code=504,
            content={"result": "fail", "message": "SSO 서버 응답 시간 초과"},
        )
    except Exception as e:
        logger.error(f"SSO proxy error: {e}")
        return JSONResponse(
            status_code=502,
            content={"result": "fail", "message": "SSO 서버 연결 실패"},
        )


@router.post("/verify-otp")
async def auth_verify_otp(req: OtpVerifyRequest, request: Request):
    """OTP 검증 → 정식 인증 토큰 발급."""
    _check_rate_limit(request, "verify_otp", 10, 60)
    entry = _pre_auth_store.get(req.pre_auth_token)
    if not entry:
        from fastapi import HTTPException
        raise HTTPException(401, "인증 세션이 유효하지 않습니다. 다시 로그인해주세요")
    now = _time_mod.time()
    if now > entry["expiry"]:
        _pre_auth_store.pop(req.pre_auth_token, None)
        from fastapi import HTTPException
        raise HTTPException(401, "인증 시간이 만료되었습니다. 다시 로그인해주세요")
    entry["attempts"] += 1
    if entry["attempts"] > OTP_MAX_ATTEMPTS:
        _pre_auth_store.pop(req.pre_auth_token, None)
        from fastapi import HTTPException
        raise HTTPException(401, "인증 시도 횟수를 초과했습니다. 다시 로그인해주세요")
    if not _hmac_mod.compare_digest(req.otp.strip(), entry["otp"]):
        remaining = OTP_MAX_ATTEMPTS - entry["attempts"]
        from fastapi import HTTPException
        raise HTTPException(401, f"인증번호가 올바르지 않습니다 (남은 시도: {remaining}회)")
    # 검증 성공
    empno = entry["empno"]
    _pre_auth_store.pop(req.pre_auth_token, None)
    token = _generate_token(empno)
    await asyncio.to_thread(_update_last_login, empno)
    logger.info(f"OTP 인증 성공: empno={empno}")
    return JSONResponse(status_code=200,
                        content={"result": "ok", "token": token, "expiresIn": AUTH_TOKEN_EXPIRY})


@router.post("/resend-otp")
async def auth_resend_otp(req: OtpResendRequest, request: Request):
    """OTP 재발송."""
    from fastapi import HTTPException
    _check_rate_limit(request, "resend_otp", 5, 60)
    entry = _pre_auth_store.get(req.pre_auth_token)
    if not entry:
        raise HTTPException(401, "인증 세션이 유효하지 않습니다. 다시 로그인해주세요")
    now = _time_mod.time()
    if now > entry["expiry"]:
        _pre_auth_store.pop(req.pre_auth_token, None)
        raise HTTPException(401, "인증 시간이 만료되었습니다. 다시 로그인해주세요")
    empno, phone = entry["empno"], entry["phone"]
    rate_ts = [t for t in _sms_rate_store.get(empno, []) if now - t < SMS_RATE_WINDOW]
    if len(rate_ts) >= SMS_RATE_MAX:
        raise HTTPException(429, f"SMS 발송 횟수를 초과했습니다. {SMS_RATE_WINDOW // 60}분 후 재시도하세요")
    rate_ts.append(now)
    _sms_rate_store[empno] = rate_ts
    try:
        otp = await asyncio.to_thread(_send_otp_sync, phone, empno)
        entry["otp"] = otp
        entry["attempts"] = 0
        entry["expiry"] = now + PRE_AUTH_EXPIRY
    except Exception as e:
        logger.error(f"OTP 재발송 실패: {e}")
        raise HTTPException(503, "SMS 발송에 실패했습니다. 잠시 후 다시 시도하세요")
    return {"result": "ok", "masked_phone": _mask_phone(phone), "expires_in": PRE_AUTH_EXPIRY}


@router.post("/logout")
async def auth_logout(request: Request):
    """로그아웃: 현재 토큰을 서버 블랙리스트에 등록하여 즉시 무효화."""
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if token:
        _blacklist_token(token)
    return {"success": True}


@router.post("/refresh")
async def auth_refresh_token(request: Request):
    """현재 유효한 토큰으로 새 토큰 발급 (세션 연장용)."""
    empno = await _verify_auth(request)
    new_token = _generate_token(empno)
    return {"token": new_token, "expiresIn": AUTH_TOKEN_EXPIRY}


@router.post("/dev-login")
async def dev_login(req: DevLoginRequest):
    """개발용 테스트 로그인 (SSO 인증 없이 임의 계정으로 토큰 발급).

    DEV_LOGIN_ENABLED=1 환경변수 + APP_ENV!=production 일 때만 허용.
    """
    from fastapi import HTTPException
    if not DEV_LOGIN_ENABLED:
        raise HTTPException(403, "개발 모드가 비활성화되어 있습니다")
    if IS_PROD:
        raise HTTPException(403, "운영 환경에서는 dev-login 사용 불가")
    if req.role not in VALID_ROLES:
        raise HTTPException(400, f"유효하지 않은 역할: {req.role}")

    token = _generate_token(req.empno)
    _dev_users[req.empno] = {
        "name": req.name, "region": req.region,
        "team": req.team, "role": req.role,
    }
    logger.info(f"[DEV-LOGIN] empno={req.empno}, name={req.name}, region={req.region}, role={req.role}")

    return {
        "result": "ok",
        "token": token,
        "expiresIn": AUTH_TOKEN_EXPIRY,
        "dev_mode": True,
        "user": {
            "empno": req.empno,
            "name": req.name,
            "region": req.region,
            "team": req.team,
            "role": req.role,
        },
    }


@router.get("/dev-login/status")
async def dev_login_status(request: Request):
    """개발 로그인 모드 활성화 여부 확인."""
    if IS_PROD:
        return {"enabled": False}
    return {"enabled": DEV_LOGIN_ENABLED}
