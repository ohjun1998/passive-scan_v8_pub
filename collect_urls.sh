#!/bin/bash
GROUP=${1:-"00"}
TARGETS_FILE="targets.txt" # SAFE_DOMAIN:SUBDOMAIN 형태의 텍스트

mkdir -p results
touch global_js_db.txt

echo "==================================================================="
echo "🚀 [Node-$GROUP] 정찰 파이프라인 가동 (MapReduce 기반 분산 스캔)"
echo "==================================================================="

# 1. 태그(SAFE_DOMAIN)를 기준으로 타겟들을 분리 저장 (동시 파일 접근 충돌 방지)
awk -F':' '{print $2 > "results/"$1"_all_targets.txt"}' $TARGETS_FILE

for TARGET_FILE in results/*_all_targets.txt; do
  [ -e "$TARGET_FILE" ] || continue
  
  BASENAME=$(basename "$TARGET_FILE")
  SAFE_DOMAIN=${BASENAME%_all_targets.txt}
  
  echo "=================================================="
  echo "🎯 [Target: $SAFE_DOMAIN] 할당된 서브도메인 병렬 스캔 가동"
  echo "=================================================="

  # 그룹(Node) 번호를 파일명에 부여하여 Artifact 병합 시 Overwrite 방지
  (
    echo "  [+] 🏛️ [Waybackurls] 병렬 추출 중..."
    cat "$TARGET_FILE" | waybackurls | uro > "results/${SAFE_DOMAIN}_waybackurls_${GROUP}.txt" 2>/dev/null
  ) &

  (
    echo "  [+] 🌐 [GAU] 위협 인텔리전스 추출 중..."
    cat "$TARGET_FILE" | gau --threads 5 | uro > "results/${SAFE_DOMAIN}_gau_${GROUP}.txt" 2>/dev/null
  ) &

  (
    echo "  [+] 🕷️ [Katana] 스텔스 크롤링 중..."
    katana -list "$TARGET_FILE" -d 2 -c 5 -rl 50 -jc -silent | uro > "results/${SAFE_DOMAIN}_katana_${GROUP}.txt" 2>/dev/null
  ) &

  wait
  echo "  [*] ✅ 해당 서브도메인 묶음의 딥 스캔 완료!"

  # JS 파일 다운로드 로직
  cat "results/${SAFE_DOMAIN}_"*"_${GROUP}.txt" 2>/dev/null | grep -iE '\.js($|\?)' | awk -F '?' '{print $1}' | sort -u > "results/${SAFE_DOMAIN}_js_targets.txt"
  
  if [ -s "results/${SAFE_DOMAIN}_js_targets.txt" ]; then
    grep -v -F -f global_js_db.txt "results/${SAFE_DOMAIN}_js_targets.txt" > "results/${SAFE_DOMAIN}_js_new.txt" 2>/dev/null || cat "results/${SAFE_DOMAIN}_js_targets.txt" > "results/${SAFE_DOMAIN}_js_new.txt"
    
    JS_NEW=$(wc -l < "results/${SAFE_DOMAIN}_js_new.txt")
    if [ "$JS_NEW" -gt 0 ]; then
      head -n 1000 "results/${SAFE_DOMAIN}_js_new.txt" > "results/${SAFE_DOMAIN}_js_final.txt"
      mkdir -p "results/${SAFE_DOMAIN}_js_files_${GROUP}"
      
      echo "  [+] 📥 JS 다운로드 (신규: $JS_NEW 개) 진행 중..."
      cat "results/${SAFE_DOMAIN}_js_final.txt" | xargs -I {} -P 10 sh -c '
        url="{}"
        filename=$(basename "$url")
        curl -s -f -m 3 --create-dirs -o "results/'${SAFE_DOMAIN}'_js_files_'${GROUP}'/$filename" "$url" && echo "$url" >> global_js_db.txt
      '
    fi
  fi
done
