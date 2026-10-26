FROM python:3.12-slim

# Build deps for native wheels (onnxruntime for the turn detector, etc.)
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent/ ./agent/
COPY assets/ ./assets/
COPY main.py .

# Pre-download Silero VAD + turn-detector model weights so cold starts don't fetch them.
RUN python main.py download-files

# Health check endpoint the framework serves automatically.
EXPOSE 8081

CMD ["python", "main.py", "start"]
