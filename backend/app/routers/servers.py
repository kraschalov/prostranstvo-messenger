"""Публичный каталог серверов (кэш GitHub) для клиентов."""
from fastapi import APIRouter, Depends

from app import directory
from app.deps import current_user

router = APIRouter(prefix="/api/servers", tags=["servers"])


@router.get("/directory")
def servers_directory(user: dict = Depends(current_user)):
    return directory.get()
