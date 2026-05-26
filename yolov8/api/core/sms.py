"""
sms - Celery SMS 클라이언트 초기화 (선택적)

담당 도메인: SMS 2차 인증 발송
주요 의존성: core.config (환경변수)
엔드포인트: 없음

주의사항:
- SMS_BROKER_HOST/USER/PASSWORD 미설정 시 HAS_SMS=False (개발모드: OTP 로그 출력)
- Celery 패키지 없으면 경고만 (서버 기동 보장)
"""

import os
import logging

logger = logging.getLogger(__name__)

SMS_BROKER_HOST     = os.environ.get("SMS_BROKER_HOST", "")
SMS_BROKER_PORT     = os.environ.get("SMS_BROKER_PORT", "5672")
SMS_BROKER_USER     = os.environ.get("SMS_BROKER_USER", "")
SMS_BROKER_PASSWORD = os.environ.get("SMS_BROKER_PASSWORD", "")
SMS_SENDER_NUMBER   = os.environ.get("SMS_SENDER_NUMBER", "")

HAS_SMS = False
_sms_app = None

try:
    if SMS_BROKER_HOST and SMS_BROKER_USER and SMS_BROKER_PASSWORD:
        from celery import Celery as _Celery
        _broker_url = f"amqp://{SMS_BROKER_USER}:{SMS_BROKER_PASSWORD}@{SMS_BROKER_HOST}:{SMS_BROKER_PORT}"
        _sms_app = _Celery("ksa_sms_client", broker=_broker_url, set_as_current=False)
        HAS_SMS = True
        logger.info("SMS Celery 클라이언트 초기화 완료")
    else:
        logger.warning("SMS_BROKER_HOST/USER/PASSWORD 미설정 — SMS 2차 인증 개발모드 (OTP 로그 출력)")
except ImportError:
    logger.warning("celery 패키지 없음 — pip install celery[rabbitmq]")
except Exception as _e:
    logger.warning(f"SMS Celery 초기화 실패: {_e}")
