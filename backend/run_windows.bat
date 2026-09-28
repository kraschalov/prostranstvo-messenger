@echo off
REM Запуск ноды мессенджера под Windows.
REM Первый раз: скопируй .env.example в .env и заполни.
if not exist .env (
  echo [.env not found, copy from .env.example]
  copy .env.example .env
  echo Edit .env now, then run again.
  pause
  exit /b 1
)
py -3.12 -m pip install -r requirements-windows.txt
py -3.12 run.py
pause
