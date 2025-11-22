# Backend de referencia (FastAPI)

Ejemplo mínimo de backend que expone `POST /decode` recibiendo una imagen
y devolviendo los bits. Puedes pegar tu implementación real aquí.

```python
# fastapi_app.py
from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse
from PIL import Image
import numpy as np
import io

app = FastAPI()

@app.post("/decode")
async def decode(file: UploadFile = File(...)):
    data = await file.read()
    try:
        img = Image.open(io.BytesIO(data)).convert("RGB")
        # Llama aquí a tu lógica Python real de decodificación (OpenCV/PIL).
        # Para el ejemplo devolvemos mocks:
        return JSONResponse({
            "product_bits": "101100110",
            "date_bits": "010011010",
            "meta": {"note": "mock response"}
        })
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=400)

# Ejecutar: uvicorn fastapi_app:app --reload --host 0.0.0.0 --port 8000
```
