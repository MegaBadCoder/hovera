#!/bin/zsh
# Перебор настроек через переменные окружения: tune.sh "ИМЯ=знач ИМЯ=знач" ...
HERE=${0:A:h}
for cfg in "$@"; do
  echo "== $cfg"
  env ${=cfg} $HERE/run.sh tune 2>&1 | grep -E "truth A\+B|truth ≥60|swing10 \(|creep \(|30-120|2-5 min|5\+ min"
done
