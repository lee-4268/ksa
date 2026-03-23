#!/usr/bin/env python3
"""KCA Import를 별도 프로세스로 실행하는 워커 스크립트.
uvicorn API 서버와 독립적으로 실행되어 API 서버가 블록되지 않음.

사용법: python3 inspection_worker.py <job_id> <s3_key> <year> <uploaded_by>
"""
import sys
import os
import logging

# main.py와 같은 디렉토리에서 실행
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s:%(name)s:%(message)s')
logger = logging.getLogger('inspection_worker')

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <job_id> <s3_key> <year> <uploaded_by>")
        sys.exit(1)

    job_id = sys.argv[1]
    s3_key = sys.argv[2]
    year = int(sys.argv[3])
    uploaded_by = sys.argv[4]

    logger.info(f"별도 프로세스 시작: job={job_id} year={year}")

    # main.py import — FastAPI app은 생성되지만 uvicorn이 아니라 서버는 시작 안 됨
    try:
        from main import _process_inspection_sync
        _process_inspection_sync(job_id, s3_key, year, uploaded_by)
        logger.info(f"완료: job={job_id}")
    except Exception as e:
        logger.error(f"실패: job={job_id} error={e}", exc_info=True)
        # 에러 상태를 DB에 기록
        try:
            import sqlite3
            from main import _INSP_DB
            from datetime import datetime, timezone
            conn = sqlite3.connect(_INSP_DB, timeout=60)
            conn.execute(
                'UPDATE inspection_jobs SET status=?, stage=?, updated_at=? WHERE job_id=?',
                ('error', f'실패: {e}', datetime.now(timezone.utc).isoformat(), job_id))
            conn.commit()
            conn.close()
        except Exception:
            pass
        sys.exit(1)
