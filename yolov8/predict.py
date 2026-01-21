"""
철탑/안테나 분류 추론 스크립트
학습된 YOLOv8 모델로 이미지 분류 수행

지원 기능:
- 단일 이미지 분류
- 다중 이미지 종합 판단 (여러 방향 사진을 종합하여 최종 판단)
"""

import os
import shutil
import json
import argparse
import numpy as np
from pathlib import Path
from typing import List, Dict, Union, Tuple
from collections import defaultdict
from ultralytics import YOLO


# 클래스 한글 매핑 (9개 클래스)
CLASS_NAMES_KR = {
    'simple_pole': '간이폴, 분산폴 및 비기준 설치대',
    'steel_pipe': '강관주',
    'complex_type': '복합형',
    'indoor': '옥내, 터널, 지하 등',
    'single_pole_building': '원폴(건물)',
    'tower_building': '철탑(건물)',
    'tower_ground': '철탑(지면)',
    'telecom_pole': '통신주',
    'frame_mount': '프레임'
}

# 짧은 클래스명 매핑
SHORT_NAMES = {
    '간이폴, 분산폴 및 비기준 설치대': '간이폴',
    '강관주': '강관주',
    '복합형': '복합형',
    '옥내, 터널, 지하 등': '옥내',
    '원폴(건물)': '원폴건물',
    '철탑(건물)': '철탑건물',
    '철탑(지면)': '철탑지면',
    '통신주': '통신주',
    '프레임': '프레임'
}


def load_model(model_path: str) -> YOLO:
    """학습된 모델 로드"""
    if not Path(model_path).exists():
        raise FileNotFoundError(f"모델 파일을 찾을 수 없습니다: {model_path}")
    return YOLO(model_path)


def predict_single_with_probs(model: YOLO, image_path: str) -> Tuple[Dict, np.ndarray]:
    """
    단일 이미지 추론 + 전체 클래스 확률값 반환
    종합 판단에 사용
    """
    results = model(image_path, verbose=False)
    result = results[0]

    probs = result.probs
    all_probs = probs.data.cpu().numpy()  # 전체 클래스 확률값
    class_names = result.names

    return class_names, all_probs


def ensemble_predict(
    model: YOLO,
    image_paths: List[str],
    method: str = 'mean',
    conf_threshold: float = 0.5
) -> Dict:
    """
    여러 이미지를 종합하여 최종 판단

    Args:
        model: YOLO 모델
        image_paths: 이미지 경로 리스트 (같은 국소의 여러 방향 사진)
        method: 종합 방식 ('mean': 평균, 'max': 최대값, 'vote': 투표)
        conf_threshold: 신뢰도 임계값

    Returns:
        종합 판단 결과
    """
    if not image_paths:
        raise ValueError("이미지가 없습니다.")

    all_probs_list = []
    individual_predictions = []
    class_names = None

    # 각 이미지별 예측 및 확률값 수집
    for img_path in image_paths:
        names, probs = predict_single_with_probs(model, img_path)
        class_names = names
        all_probs_list.append(probs)

        # 개별 예측 결과도 저장
        top1_idx = np.argmax(probs)
        individual_predictions.append({
            'image_path': str(img_path),
            'prediction': names[top1_idx],
            'confidence': float(probs[top1_idx])
        })

    # 확률값 종합
    probs_array = np.array(all_probs_list)

    if method == 'mean':
        # 평균 확률
        ensemble_probs = np.mean(probs_array, axis=0)
    elif method == 'max':
        # 최대 확률
        ensemble_probs = np.max(probs_array, axis=0)
    elif method == 'vote':
        # 투표 방식 (각 이미지에서 1위인 클래스에 투표)
        votes = np.zeros(len(class_names))
        for probs in probs_array:
            votes[np.argmax(probs)] += 1
        ensemble_probs = votes / len(probs_array)
    else:
        ensemble_probs = np.mean(probs_array, axis=0)

    # 최종 결과
    final_idx = np.argmax(ensemble_probs)
    final_class = class_names[final_idx]
    final_class_kr = CLASS_NAMES_KR.get(final_class, final_class)
    final_conf = float(ensemble_probs[final_idx])

    # Top-5 결과
    top5_indices = np.argsort(ensemble_probs)[::-1][:5]
    top5_results = [
        {
            'class': class_names[idx],
            'class_kr': CLASS_NAMES_KR.get(class_names[idx], class_names[idx]),
            'confidence': round(float(ensemble_probs[idx]), 4)
        }
        for idx in top5_indices
    ]

    result = {
        'ensemble_method': method,
        'num_images': len(image_paths),
        'image_paths': [str(p) for p in image_paths],
        'final_prediction': {
            'class': final_class,
            'class_kr': final_class_kr,
            'confidence': round(final_conf, 4)
        },
        'top5': top5_results,
        'individual_predictions': individual_predictions,
        'is_confident': final_conf >= conf_threshold
    }

    return result


def predict_single(model: YOLO, image_path: str, conf_threshold: float = 0.5) -> Dict:
    """단일 이미지 추론"""
    results = model(image_path, verbose=False)
    result = results[0]

    # 분류 결과 추출
    probs = result.probs
    top1_idx = probs.top1
    top1_conf = probs.top1conf.item()
    top5_indices = probs.top5
    top5_confs = probs.top5conf.tolist()

    # 클래스 이름 가져오기
    class_names = result.names
    top1_class = class_names[top1_idx]
    top1_class_kr = CLASS_NAMES_KR.get(top1_class, top1_class)

    prediction = {
        'image_path': str(image_path),
        'prediction': {
            'class': top1_class,
            'class_kr': top1_class_kr,
            'confidence': round(top1_conf, 4)
        },
        'top5': [
            {
                'class': class_names[idx],
                'class_kr': CLASS_NAMES_KR.get(class_names[idx], class_names[idx]),
                'confidence': round(conf, 4)
            }
            for idx, conf in zip(top5_indices, top5_confs)
        ],
        'is_confident': top1_conf >= conf_threshold
    }

    return prediction


def predict_batch(
    model: YOLO,
    image_paths: List[str],
    conf_threshold: float = 0.5,
    batch_size: int = 16
) -> List[Dict]:
    """배치 이미지 추론"""
    predictions = []

    for i in range(0, len(image_paths), batch_size):
        batch_paths = image_paths[i:i + batch_size]
        results = model(batch_paths, verbose=False)

        for result, img_path in zip(results, batch_paths):
            probs = result.probs
            top1_idx = probs.top1
            top1_conf = probs.top1conf.item()
            top5_indices = probs.top5
            top5_confs = probs.top5conf.tolist()

            class_names = result.names
            top1_class = class_names[top1_idx]
            top1_class_kr = CLASS_NAMES_KR.get(top1_class, top1_class)

            prediction = {
                'image_path': str(img_path),
                'prediction': {
                    'class': top1_class,
                    'class_kr': top1_class_kr,
                    'confidence': round(top1_conf, 4)
                },
                'top5': [
                    {
                        'class': class_names[idx],
                        'class_kr': CLASS_NAMES_KR.get(class_names[idx], class_names[idx]),
                        'confidence': round(conf, 4)
                    }
                    for idx, conf in zip(top5_indices, top5_confs)
                ],
                'is_confident': top1_conf >= conf_threshold
            }
            predictions.append(prediction)

    return predictions


def predict_directory(
    model: YOLO,
    directory: str,
    conf_threshold: float = 0.5,
    extensions: tuple = ('.jpg', '.jpeg', '.png', '.bmp', '.webp')
) -> List[Dict]:
    """디렉토리 내 모든 이미지 추론"""
    dir_path = Path(directory)
    if not dir_path.is_dir():
        raise NotADirectoryError(f"디렉토리를 찾을 수 없습니다: {directory}")

    image_paths = []
    for ext in extensions:
        image_paths.extend(dir_path.glob(f'**/*{ext}'))
        image_paths.extend(dir_path.glob(f'**/*{ext.upper()}'))

    image_paths = [str(p) for p in sorted(set(image_paths))]
    print(f"발견된 이미지: {len(image_paths)}개")

    return predict_batch(model, image_paths, conf_threshold)


def save_results(predictions: List[Dict], output_path: str):
    """결과를 JSON 파일로 저장"""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(predictions, f, ensure_ascii=False, indent=2)

    print(f"결과 저장: {output_path}")


def rename_files_by_prediction(predictions: List[Dict], use_short_name: bool = True):
    """
    예측 결과에 따라 파일명 변경
    예: sample.png → sample_강관주.png
    """
    renamed_files = []

    for pred in predictions:
        original_path = Path(pred['image_path'])
        class_kr = pred['prediction']['class_kr']

        # 짧은 이름 사용 여부
        if use_short_name:
            class_label = SHORT_NAMES.get(class_kr, class_kr)
        else:
            class_label = class_kr

        # 새 파일명 생성: 원본명_클래스명.확장자
        new_name = f"{original_path.stem}_{class_label}{original_path.suffix}"
        new_path = original_path.parent / new_name

        # 파일명 변경
        if original_path.exists() and not new_path.exists():
            shutil.move(str(original_path), str(new_path))
            renamed_files.append({
                'original': str(original_path),
                'renamed': str(new_path),
                'class': class_kr
            })
            print(f"  {original_path.name} → {new_name}")
        elif new_path.exists():
            print(f"  {original_path.name} → (이미 존재: {new_name})")

    return renamed_files


def print_summary(predictions: List[Dict]):
    """추론 결과 요약 출력"""
    if not predictions:
        print("추론 결과가 없습니다.")
        return

    print("\n" + "=" * 60)
    print("추론 결과 요약")
    print("=" * 60)

    # 클래스별 개수 집계
    class_counts = {}
    confident_count = 0

    for pred in predictions:
        cls = pred['prediction']['class_kr']
        class_counts[cls] = class_counts.get(cls, 0) + 1
        if pred['is_confident']:
            confident_count += 1

    print(f"\n총 이미지: {len(predictions)}개")
    print(f"신뢰도 기준 충족: {confident_count}개 ({confident_count/len(predictions)*100:.1f}%)")
    print("\n클래스별 분포:")
    for cls, count in sorted(class_counts.items(), key=lambda x: -x[1]):
        print(f"  - {cls}: {count}개 ({count/len(predictions)*100:.1f}%)")

    print("=" * 60)


def print_ensemble_result(result: Dict):
    """종합 판단 결과 출력"""
    print("\n" + "=" * 60)
    print("다중 이미지 종합 판단 결과")
    print("=" * 60)

    print(f"\n분석 이미지 수: {result['num_images']}장")
    print(f"종합 방식: {result['ensemble_method']}")

    print(f"\n최종 판단: {result['final_prediction']['class_kr']}")
    print(f"종합 신뢰도: {result['final_prediction']['confidence']:.2%}")

    print("\n개별 이미지 예측:")
    for i, pred in enumerate(result['individual_predictions'], 1):
        img_name = Path(pred['image_path']).name
        pred_kr = CLASS_NAMES_KR.get(pred['prediction'], pred['prediction'])
        print(f"  {i}. {img_name}: {pred_kr} ({pred['confidence']:.2%})")

    print("\nTop-5 종합 예측:")
    for i, p in enumerate(result['top5'], 1):
        print(f"  {i}. {p['class_kr']}: {p['confidence']:.2%}")

    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description='철탑/안테나 분류 추론',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
사용 예시:
  # 단일 이미지 분류
  python predict.py --model best.pt --source image.jpg

  # 폴더 내 이미지 개별 분류
  python predict.py --model best.pt --source images/

  # 여러 이미지 종합 판단 (같은 국소의 여러 방향 사진)
  python predict.py --model best.pt --source images/ --ensemble

  # 종합 판단 + 파일명 변경
  python predict.py --model best.pt --source images/ --ensemble --rename
        """
    )
    parser.add_argument('--model', type=str, required=True,
                        help='학습된 모델 경로')
    parser.add_argument('--source', type=str, required=True,
                        help='입력 이미지 또는 디렉토리 경로')
    parser.add_argument('--output', type=str, default='results/predictions.json',
                        help='결과 저장 경로')
    parser.add_argument('--conf', type=float, default=0.5,
                        help='신뢰도 임계값 (기본: 0.5)')
    parser.add_argument('--batch-size', type=int, default=16,
                        help='배치 크기 (기본: 16)')
    parser.add_argument('--rename', action='store_true',
                        help='예측 결과에 따라 파일명 변경')
    parser.add_argument('--ensemble', action='store_true',
                        help='여러 이미지를 종합하여 최종 판단 (같은 국소의 여러 방향 사진)')
    parser.add_argument('--ensemble-method', type=str, default='mean',
                        choices=['mean', 'max', 'vote'],
                        help='종합 판단 방식: mean(평균), max(최대), vote(투표) (기본: mean)')

    args = parser.parse_args()

    # 모델 로드
    print(f"모델 로드 중: {args.model}")
    model = load_model(args.model)

    # 추론 실행
    source_path = Path(args.source)

    # 종합 판단 모드
    if args.ensemble:
        if source_path.is_dir():
            # 디렉토리 내 모든 이미지를 종합 판단
            extensions = ('.jpg', '.jpeg', '.png', '.bmp', '.webp')
            image_paths = []
            for ext in extensions:
                image_paths.extend(source_path.glob(f'*{ext}'))
                image_paths.extend(source_path.glob(f'*{ext.upper()}'))
            image_paths = sorted(set(image_paths))

            if not image_paths:
                raise ValueError(f"디렉토리에 이미지가 없습니다: {args.source}")

            print(f"\n종합 판단 모드: {len(image_paths)}장의 이미지 분석")
            result = ensemble_predict(
                model,
                [str(p) for p in image_paths],
                method=args.ensemble_method,
                conf_threshold=args.conf
            )

            # 결과 저장 및 출력
            save_results(result, args.output)
            print_ensemble_result(result)

            # 파일명 변경 (종합 결과 기준)
            if args.rename:
                final_class = result['final_prediction']['class_kr']
                short_name = SHORT_NAMES.get(final_class, final_class)
                print(f"\n파일명 변경 중... (종합 결과: {short_name})")
                for img_path in image_paths:
                    original = Path(img_path)
                    new_name = f"{original.stem}_{short_name}{original.suffix}"
                    new_path = original.parent / new_name
                    if original.exists() and not new_path.exists():
                        shutil.move(str(original), str(new_path))
                        print(f"  {original.name} → {new_name}")
                print("파일명 변경 완료!")

        else:
            raise ValueError("종합 판단 모드는 디렉토리를 입력해야 합니다.")

    # 개별 판단 모드
    else:
        if source_path.is_file():
            print(f"단일 이미지 추론: {args.source}")
            predictions = [predict_single(model, args.source, args.conf)]
        elif source_path.is_dir():
            print(f"디렉토리 추론: {args.source}")
            predictions = predict_directory(model, args.source, args.conf)
        else:
            raise ValueError(f"유효하지 않은 경로: {args.source}")

        # 결과 저장 및 출력
        save_results(predictions, args.output)
        print_summary(predictions)

        # 단일 이미지인 경우 상세 결과 출력
        if len(predictions) == 1:
            pred = predictions[0]
            print(f"\n예측 결과: {pred['prediction']['class_kr']}")
            print(f"신뢰도: {pred['prediction']['confidence']:.2%}")
            print("\nTop-5 예측:")
            for i, p in enumerate(pred['top5'], 1):
                print(f"  {i}. {p['class_kr']}: {p['confidence']:.2%}")

        # 파일명 변경 옵션
        if args.rename:
            print("\n파일명 변경 중...")
            rename_files_by_prediction(predictions)
            print("파일명 변경 완료!")


if __name__ == '__main__':
    main()
