"""
auth - 인증/로그인/OTP/토큰 갱신 엔드포인트

담당 도메인: 사용자 인증
주요 의존성: core.auth, core.config, core.sso_verify
엔드포인트:
    POST /auth/login          (외부 SSO 1차 + 인프라가 SMS 직접 발송)
    POST /auth/verify-otp     (외부 SSO 에 OTP 프록시 + 우리 자체 토큰 발급)
    POST /auth/resend-otp     (사용자에게 1차 재시도 안내)
    POST /auth/logout
    POST /auth/refresh
    POST /auth/dev-login
    GET  /auth/dev-login/status

설계 변경 이력 (2026-06-01):
    인프라가 auth2.skons.net 에 통합 인증 서비스를 출시. SSO + SMS 발송 +
    OTP 검증이 한 도메인에 묶이고, 기존 /accounts/sko/sso/login/ 는 곧 폐기.
    우리 백엔드는 "중계" 역할로 변경 — 인프라 호출 결과를 받아 우리 자체
    HMAC 토큰을 발급(클라이언트 영향 없음). 인프라가 발급한 JWT 액세스/
    리프레시 쿠키는 sub 일치 sanity check 후 폐기 (JWKS 미제공 상태이므로
    완전한 RS256 서명 검증은 향후 보강 예정 — core/sso_verify.py 참조).
"""

import asyncio
import json
import logging
import time as _time_mod

import httpx
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse

from core.auth import (
    _verify_auth, _verify_token, _verify_token_full, _generate_token,
    _blacklist_token, _real_role_sync, _sanitize_preview,
    _get_user_role_info, _ensure_user_in_roles_sync, _update_last_login,
    _get_user_phone_sync, _mask_phone, _normalize_empno,
    _pre_auth_store, _sms_rate_store, _dev_users, _record_audit_log_sync,
)
from core.config import (
    SSO_LOGIN_URL, SSO_VERIFY_URL, DEV_LOGIN_ENABLED, IS_PROD, VALID_ROLES,
    AUTH_TOKEN_EXPIRY,
)
from core.sso_verify import verify_access_token
from core.utils import _check_rate_limit, _get_client_ip
from schemas.models import LoginRequest, OtpVerifyRequest, OtpResendRequest, DevLoginRequest

router = APIRouter(prefix="/auth", tags=["auth"])
logger = logging.getLogger(__name__)

# OTP 관련 상수 (core.auth에서 re-import)
from core.auth import (
    PRE_AUTH_EXPIRY, OTP_MAX_ATTEMPTS, SMS_RATE_MAX, SMS_RATE_WINDOW
)
import secrets as _secrets_mod


@router.post("/login")
async def proxy_sso_login(req: LoginRequest, request: Request):
    """SKons SSO 통합 인증 1차 — 사번/비번 검증 + 인프라 측이 SMS OTP 직접 발송."""
    _check_rate_limit(request, "login", 5, 60)
    username = _normalize_empno(req.username)  # 사번 대문자 정규화 (test_ 계정은 원문 유지)

    # 우리 측 SMS 발송 횟수 제한 (인프라 측에도 있겠지만 1차 방어선)
    now = _time_mod.time()
    rate_ts = [t for t in _sms_rate_store.get(username, []) if now - t < SMS_RATE_WINDOW]
    if len(rate_ts) >= SMS_RATE_MAX:
        return JSONResponse(
            status_code=429,
            content={"result": "fail", "message": f"SMS 발송 횟수를 초과했습니다. {SMS_RATE_WINDOW // 60}분 후 재시도하세요."},
        )

    # 인프라 SSO 호출
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            sso_resp = await client.post(
                SSO_LOGIN_URL,
                json={"username": username, "password": req.password},
                headers={"Content-Type": "application/json"},
            )
    except httpx.TimeoutException:
        return JSONResponse(
            status_code=504,
            content={"result": "fail", "message": "SSO 서버 응답 시간 초과"},
        )
    except Exception as e:
        logger.error(f"SSO 호출 실패: {e}")
        return JSONResponse(
            status_code=502,
            content={"result": "fail", "message": "SSO 서버 연결 실패"},
        )

    # 인증 실패 → 응답 그대로 전달
    if sso_resp.status_code != 200:
        try:
            body = sso_resp.json()
        except Exception:
            body = {"result": "fail", "message": "인증에 실패했습니다"}
        return JSONResponse(status_code=sso_resp.status_code, content=body)

    sso_data = sso_resp.json()
    if sso_data.get("status") != "sms_sent":
        # 인프라가 200 으로 답했지만 sms_sent 가 아닌 케이스 — 그대로 전달
        return JSONResponse(status_code=200, content=sso_data)

    # SSO 1차 통과 — 우리 측 휴면계정 차단/등록
    role_info = await asyncio.to_thread(_get_user_role_info, username)
    if role_info["is_dormant"]:
        return JSONResponse(
            status_code=403,
            content={"result": "fail", "message": "휴면 계정입니다. 관리자에게 문의하거나 이메일 인증을 진행해 주세요."},
        )
    await asyncio.to_thread(_ensure_user_in_roles_sync, username)

    # 인프라 응답에서 login_session 쿠키 추출
    login_session = sso_resp.cookies.get("login_session")
    if not login_session:
        logger.error(f"SSO 1차 통과했지만 login_session 쿠키 없음: empno={username}")
        return JSONResponse(
            status_code=502,
            content={"result": "fail", "message": "SSO 세션 발급 실패. 잠시 후 다시 시도하세요."},
        )

    # SMS 발송 카운트 기록
    rate_ts.append(now)
    _sms_rate_store[username] = rate_ts

    # pre_auth_token 발급 + login_session 매핑 저장
    pre_auth_token = _secrets_mod.token_urlsafe(32)
    _pre_auth_store[pre_auth_token] = {
        "empno": username,
        "login_session": login_session,
        "expiry": now + PRE_AUTH_EXPIRY,
        "attempts": 0,
    }

    # 마스킹용 전화번호는 우리 DynamoDB 에서 조회 (인프라가 안 주므로)
    phone = await asyncio.to_thread(_get_user_phone_sync, username)
    masked = _mask_phone(phone or "") if phone else "(등록된 번호)"

    return JSONResponse(
        status_code=200,
        content={
            "result": "otp_required",
            "pre_auth_token": pre_auth_token,
            "masked_phone": masked,
            "expires_in": PRE_AUTH_EXPIRY,
        },
    )


@router.post("/verify-otp")
async def auth_verify_otp(req: OtpVerifyRequest, request: Request):
    """OTP 검증 — 인프라 verify 프록시 호출 + 성공 시 우리 자체 인증 토큰 발급."""
    _check_rate_limit(request, "verify_otp", 10, 60)
    entry = _pre_auth_store.get(req.pre_auth_token)
    if not entry:
        raise HTTPException(401, "인증 세션이 유효하지 않습니다. 다시 로그인해주세요")
    now = _time_mod.time()
    if now > entry["expiry"]:
        _pre_auth_store.pop(req.pre_auth_token, None)
        raise HTTPException(401, "인증 시간이 만료되었습니다. 다시 로그인해주세요")
    entry["attempts"] += 1
    if entry["attempts"] > OTP_MAX_ATTEMPTS:
        _pre_auth_store.pop(req.pre_auth_token, None)
        raise HTTPException(401, "인증 시도 횟수를 초과했습니다. 다시 로그인해주세요")

    empno = entry["empno"]
    login_session = entry["login_session"]
    otp_code = req.otp.strip()

    # 인프라 verify 호출
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            verify_resp = await client.post(
                SSO_VERIFY_URL,
                json={"username": empno, "otp_code": otp_code},
                cookies={"login_session": login_session},
                headers={"Content-Type": "application/json"},
            )
    except httpx.TimeoutException:
        raise HTTPException(504, "SSO 응답 시간 초과")
    except Exception as e:
        logger.error(f"SSO verify 호출 실패: {e}")
        raise HTTPException(502, "SSO 서버 연결 실패")

    if verify_resp.status_code != 200:
        # 인프라가 거절 — 시도 횟수만큼 카운트 유지하고 401
        remaining = OTP_MAX_ATTEMPTS - entry["attempts"]
        if remaining <= 0:
            _pre_auth_store.pop(req.pre_auth_token, None)
            raise HTTPException(401, "인증 시도 횟수를 초과했습니다. 다시 로그인해주세요")
        raise HTTPException(401, f"인증번호가 올바르지 않습니다 (남은 시도: {remaining}회)")

    # 보강: 인프라가 발급한 access_token 의 sub 가 username 과 일치하는지 확인
    # (JWKS 가 설정되면 서명까지 검증 — core/sso_verify.py 참조)
    access_token = verify_resp.cookies.get("access_token", "")
    if access_token and not verify_access_token(access_token, empno):
        logger.warning(f"SSO JWT sub 불일치 또는 손상: empno={empno}")
        raise HTTPException(401, "인증 응답이 일관되지 않습니다. 다시 시도해주세요")

    # 검증 통과 — 우리 자체 토큰 발급
    _pre_auth_store.pop(req.pre_auth_token, None)
    token = _generate_token(empno)
    await asyncio.to_thread(_update_last_login, empno)
    # 감사 로그 — 프론트가 action 문자열을 AuditAction enum 이름과 대조하므로
    # 반드시 "LOGIN"/"LOGOUT" 대문자로 남긴다(불일치 시 화면에 '수정'으로 표시됨).
    await asyncio.to_thread(
        _record_audit_log_sync, "LOGIN", "User", empno, empno,
        {"newData": json.dumps({"method": "sso_otp", "ip": _get_client_ip(request)},
                               ensure_ascii=False)})
    logger.info(f"OTP 인증 성공: empno={empno}")
    return JSONResponse(
        status_code=200,
        content={"result": "ok", "token": token, "expiresIn": AUTH_TOKEN_EXPIRY},
    )


@router.post("/resend-otp")
async def auth_resend_otp(req: OtpResendRequest, request: Request):
    """OTP 재발송 — 인프라에 별도 resend 엔드포인트가 없어 /auth/login 을 재호출.

    프론트가 메모리에 보관한 비밀번호를 함께 전달 → 동일 username+password 로
    SSO 재로그인 → 인프라가 새 OTP 를 SMS 로 발송. 기존 pre_auth_token 의 entry
    는 새 login_session 으로 교체(토큰 자체는 유지) + attempts/expiry 갱신.
    """
    _check_rate_limit(request, "resend_otp", 5, 60)
    entry = _pre_auth_store.get(req.pre_auth_token)
    if not entry:
        raise HTTPException(401, "인증 세션이 유효하지 않습니다. 다시 로그인해주세요")
    now = _time_mod.time()
    if now > entry["expiry"]:
        _pre_auth_store.pop(req.pre_auth_token, None)
        raise HTTPException(401, "인증 시간이 만료되었습니다. 다시 로그인해주세요")

    empno = entry["empno"]
    password = req.password

    # 우리 측 SMS 발송 횟수 제한 (1차 로그인과 동일 카운터 공유)
    rate_ts = [t for t in _sms_rate_store.get(empno, []) if now - t < SMS_RATE_WINDOW]
    if len(rate_ts) >= SMS_RATE_MAX:
        raise HTTPException(
            status_code=429,
            detail=f"SMS 발송 횟수를 초과했습니다. {SMS_RATE_WINDOW // 60}분 후 재시도하세요.",
        )

    # SSO /auth/login 재호출 → 새 SMS 발송
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            sso_resp = await client.post(
                SSO_LOGIN_URL,
                json={"username": empno, "password": password},
                headers={"Content-Type": "application/json"},
            )
    except httpx.TimeoutException:
        raise HTTPException(504, "SSO 응답 시간 초과")
    except Exception as e:
        logger.error(f"SSO resend(login 재호출) 실패: {e}")
        raise HTTPException(502, "SSO 서버 연결 실패")

    if sso_resp.status_code != 200:
        logger.warning(
            f"SSO resend(login) 거절 [{sso_resp.status_code}] empno={empno} "
            f"body={sso_resp.text[:200]}"
        )
        try:
            body = sso_resp.json()
            msg = body.get("message") or body.get("detail") or "재발송에 실패했습니다."
        except Exception:
            msg = "재발송에 실패했습니다. 잠시 후 다시 시도해주세요."
        raise HTTPException(status_code=sso_resp.status_code, detail=msg)

    # 재호출 시 인프라는 200 + login_session 은 주지만 status 가 sms_sent 가
    # 아닌 값으로 응답하는 경우가 있음(SMS 는 실제로 발송됨). 1차 로그인과 달리
    # 재발송은 login_session 쿠키 존재만으로 성공 판정한다 (AWS-IT-RESOURCE 와 동일).
    try:
        sso_data = sso_resp.json()
    except Exception:
        sso_data = {}
    if sso_data.get("status") != "sms_sent":
        logger.info(f"SSO resend(login) status={sso_data.get('status')} empno={empno} (쿠키로 판정)")

    # 새 login_session 으로 교체 + 만료/시도 카운터 리셋
    new_session = sso_resp.cookies.get("login_session")
    if not new_session:
        logger.error(f"SSO resend(login): login_session 쿠키 없음 empno={empno}")
        raise HTTPException(502, "SMS 재발송 실패. 잠시 후 다시 시도하세요.")
    entry["login_session"] = new_session
    entry["expiry"] = now + PRE_AUTH_EXPIRY
    entry["attempts"] = 0

    # SMS 발송 카운트 기록
    rate_ts.append(now)
    _sms_rate_store[empno] = rate_ts

    # 마스킹 전화번호 (UI 갱신용) — 우리 DB 에서 조회 (인프라가 안 줌)
    phone = await asyncio.to_thread(_get_user_phone_sync, empno)
    masked = _mask_phone(phone or "") if phone else "(등록된 번호)"

    logger.info(f"OTP 재발송 성공(login 재호출): empno={empno}")
    return {
        "result": "ok",
        "masked_phone": masked,
        "expires_in": PRE_AUTH_EXPIRY,
        "resend_cooldown": 30,
    }


@router.post("/logout")
async def auth_logout(request: Request):
    """로그아웃: 현재 토큰을 서버 블랙리스트에 등록하여 즉시 무효화."""
    token = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    # empno 는 블랙리스트 등록 전에 뽑는다(등록 후에는 _verify_token 이 None 을 반환).
    # 만료·손상 토큰으로도 로그아웃은 성공시켜야 하므로 _verify_auth 를 쓰지 않는다.
    empno = _verify_token(token) if token else None
    if token:
        _blacklist_token(token)
    if empno:
        await asyncio.to_thread(
            _record_audit_log_sync, "LOGOUT", "User", empno, empno,
            {"newData": json.dumps({"ip": _get_client_ip(request)}, ensure_ascii=False)})
    return {"success": True}


@router.post("/refresh")
async def auth_refresh_token(request: Request):
    """현재 유효한 토큰으로 새 토큰 발급 (세션 연장용)."""
    empno = await _verify_auth(request)
    new_token = _generate_token(empno)
    return {"token": new_token, "expiresIn": AUTH_TOKEN_EXPIRY}


@router.post("/dev-login")
async def dev_login(req: DevLoginRequest, request: Request):
    """개발용 테스트 로그인 (SSO 인증 없이 임의 계정으로 토큰 발급).

    DEV_LOGIN_ENABLED=1 환경변수 + APP_ENV!=production 일 때만 허용.
    """
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
    await asyncio.to_thread(
        _record_audit_log_sync, "LOGIN", "User", req.empno, req.empno,
        {"newData": json.dumps({"method": "dev_login", "role": req.role,
                                "ip": _get_client_ip(request)}, ensure_ascii=False)})

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


# ══════════════════════════════════════════════════════════════
# 권한/본부 체험 (admin 전용)
# ══════════════════════════════════════════════════════════════

@router.post("/preview")
async def auth_set_preview(request: Request):
    """다른 권한·본부 계정의 화면을 체험할 토큰 발급. 실제 admin 만.

    body {role, division} — 둘 다 빈 값이면 체험 해제(평범한 토큰).
    체험 상태는 토큰에 서명돼 담기므로(core/auth.py 참조) 클라이언트는 받은
    토큰으로 갈아끼우기만 하면 모든 요청에 일관되게 적용된다.
    """
    empno = await _verify_auth(request)
    real = await asyncio.to_thread(_real_role_sync, empno)
    if real != "admin":
        raise HTTPException(403, "관리자만 사용할 수 있습니다")

    try:
        body = await request.json()
    except Exception:
        body = {}
    role, division = _sanitize_preview(
        str(body.get("role") or ""), str(body.get("division") or ""))

    token = _generate_token(empno, role, division)
    # 관리자가 다른 권한을 흉내내는 것은 추적 가능해야 한다.
    await asyncio.to_thread(
        _record_audit_log_sync, "UPDATE", "User", empno, empno,
        {"newData": json.dumps(
            {"preview_role": role or "(해제)", "preview_division": division or "(전체)",
             "ip": _get_client_ip(request)}, ensure_ascii=False)})
    logger.info(f"권한 체험 전환: empno={empno}, role={role or '해제'}, "
                f"division={division or '전체'}")
    return {
        "result": "ok",
        "token": token,
        "expiresIn": AUTH_TOKEN_EXPIRY,
        "preview": {"role": role, "division": division},
        "effective_role": role or real,
        "real_role": real,
    }


@router.get("/preview")
async def auth_get_preview(request: Request):
    """현재 토큰에 담긴 체험 상태. 새로고침 후 UI 복원용."""
    empno = await _verify_auth(request)
    auth_header = request.headers.get("Authorization", "")
    token = auth_header[7:] if auth_header.startswith("Bearer ") else ""
    _e, prole, pdiv = _verify_token_full(token)
    real = await asyncio.to_thread(_real_role_sync, empno)
    return {
        "real_role": real,
        "can_preview": real == "admin",
        "preview": {"role": prole, "division": pdiv},
        "effective_role": prole or real,
    }
