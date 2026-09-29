#!/bin/zsh
# Стенд дрейфа курса: прогоняет OrientationFilter текущего дерева по записям
# full1/full2/exp/w (full0 — при BENCH_ALL=1) с нажатиями ⌃R из events.log и печатает метрики.
# Использование: tmp/bench/run.sh <имя-варианта> [patch-файл]
#   patch-файл применяется к дереву на время прогона и откатывается после.
# Переменные: BENCH_DATA — папка с записями и events.log (по умолчанию /Users/v/projects/hovera-research).
set -e
HERE=${0:A:h}
ROOT=${HERE:h:h}
DATA=${BENCH_DATA:-/Users/v/projects/hovera-research}
NAME=${1:-current}
PATCH=${2:+${2:A}}
OUT=$HERE/out/$NAME
mkdir -p $OUT
cd $ROOT
if [ -n "$PATCH" ]; then git apply $PATCH; trap "git apply -R $PATCH" EXIT; fi
swift build --build-tests -c release -Xswiftc -enable-testing 2>&1 | grep -E "error:" && exit 1
OLD=24.011977443458576,82.71605516440869,-30.64628335146423,53.300149128282186,0.30771340177522993
NEW=22.980775323714415,82.39386138665067,-27.546536925009608,52.59850485625357,0.29489587768107667
RESETS=$(grep -o 'CORRECTION recenter.* at [0-9.]*' $DATA/events.log | awk '{print $NF}' | paste -sd, -)
SETS="full1:$OLD full2:$NEW exp:$NEW w:$NEW"
[ -n "$BENCH_ALL" ] && SETS="full0:$OLD $SETS"
for pair in ${=SETS}; do
  f=${pair%%:*}; cal=${pair#*:}
  BENCH_CSV=$DATA/$f.csv BENCH_OUT=$OUT/$f.trace BENCH_RESETS=$RESETS BENCH_CAL=$cal \
    swift test -c release -Xswiftc -enable-testing --skip-build --filter zzBenchReplay 2>&1 | grep "BENCH RESET" > $OUT/$f.resets || true
done
python3 $HERE/score.py $OUT $DATA/events.log | tee $OUT/score.txt
python3 $HERE/loops.py $OUT | tee -a $OUT/score.txt
