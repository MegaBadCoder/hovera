#!/bin/zsh
# Запускает JupyterLab с окружением анализа датчиков RayDesk.
cd "$(dirname "$0")"
if [ ! -x .venv/bin/jupyter ]; then
  echo "Окружения нет — создаю (.venv)…"
  uv venv --python 3.12 .venv
  uv pip install --python .venv/bin/python jupyterlab pandas matplotlib scipy ipykernel
fi
exec .venv/bin/jupyter lab --notebook-dir=. "$@"
