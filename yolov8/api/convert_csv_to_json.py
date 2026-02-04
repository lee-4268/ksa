"""
i-NET 사용자 CSV 파일을 FastAPI 서버용 JSON으로 변환

사용법:
  python convert_csv_to_json.py <csv_file_path>

예시:
  python convert_csv_to_json.py inet_20250204.csv

출력:
  data/users.json
"""
import csv
import json
import sys
from pathlib import Path


def convert_csv_to_json(csv_path: str, output_path: str = "data/users.json"):
    users = []

    with open(csv_path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            empno = row.get("empno", "").strip()
            if not empno:
                continue

            users.append({
                "empno": empno,
                "name": row.get("name", "").strip(),
                "Email": row.get("Email", "").strip(),
                "MobilePhone": row.get("MobilePhone", "").strip(),
                "DeptName": row.get("DeptName", "").strip(),
                "PartyTeamName": row.get("PartyTeamName", "").strip(),
                "jobGdName": row.get("jobGdName", "").strip(),
                "region": row.get("region", "").strip(),
                "HiredDate": row.get("HiredDate", "").strip(),
            })

    # 출력 디렉토리 생성
    output_dir = Path(output_path).parent
    output_dir.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(users, f, ensure_ascii=False, indent=2)

    print(f"변환 완료: {len(users)}명 → {output_path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("사용법: python convert_csv_to_json.py <csv_file_path>")
        sys.exit(1)

    convert_csv_to_json(sys.argv[1])
