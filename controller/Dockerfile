FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir tencentcloud-sdk-python
COPY app.py /app/app.py
CMD ["python3", "-m", "app"]
